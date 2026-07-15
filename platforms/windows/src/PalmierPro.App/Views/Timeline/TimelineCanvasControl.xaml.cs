using System.ComponentModel;
using Microsoft.Graphics.Canvas;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls.Primitives;
using PalmierPro.App.Editing;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Core.Models;
using PalmierPro.Services.Media;
using Windows.Foundation;

namespace PalmierPro.App.Views.Timeline;

/// Win2D timeline body (M3, Stage C) — ports the drawing half of Timeline/TimelineView.swift +
/// ClipRenderer.swift + TimelineRuler.swift + TimelineHeaderView.swift and the pointer half of
/// Timeline/TimelineInputController.swift. This file: fields, attach/detach lifecycle, the
/// coordinate-space contract, scrollbar wiring, and invalidation plumbing shared by the
/// TimelineCanvasControl.Rendering/.Input/.DragDrop partials (mirrors the Mac file split).
///
/// Coordinate-space contract: "document" pixels are what `TimelineGeometry` produces
/// (`XForFrame`/`TrackY`, header-width-inclusive, never negative). "Screen" pixels are what the
/// pointer/Draw APIs give this control. `ScreenXForFrame`/`DocXForScreen` and
/// `ScreenY`/`DocYForScreen` are the only conversions — every other method in the three partials
/// works in one space or the other, never mixes raw arithmetic. Unlike the Mac's two-NSView
/// architecture (a fixed header NSView + a scrolling NSScrollView/document view), scrolling here is
/// simulated entirely in code: `_scrollX`/`_scrollY` shift the scrollable content while the ruler
/// (fixed vertically) and header column (fixed horizontally) are drawn as opaque overlays on top —
/// see TimelineCanvasControl.Rendering.cs.
public sealed partial class TimelineCanvasControl : Microsoft.UI.Xaml.Controls.UserControl
{
    private TimelineCanvasContext? _context;
    private TimelineEditorViewModel? Vm => _context?.Vm;

    private double _pixelsPerFrame = Defaults.PixelsPerFrame;
    private double _scrollX;
    private double _scrollY;

    private string? _hoveredClipId;
    private double? _localSnapX;
    private double? _externalSnapX;

    private object? _drag;

    private readonly Dictionary<string, (IReadOnlyList<CachedThumbnail> Source, CanvasBitmap[] Bitmaps)> _thumbnailBitmaps = [];
    private readonly HashSet<string> _requestedWaveforms = [];

    private readonly Dictionary<int, Rect> _muteButtonRects = [];
    private readonly Dictionary<int, Rect> _hideButtonRects = [];
    private readonly Dictionary<int, Rect> _syncLockButtonRects = [];

    public TimelineCanvasControl()
    {
        InitializeComponent();
        Canvas.IsTabStop = true;
        Unloaded += (_, _) => Attach(null);
    }

    /// Swaps in a new document's editing surface, or tears one down (`context: null`) — called by
    /// EditorPlaceholderView.SetDocument alongside the media panel's own attach/detach.
    public void Attach(TimelineCanvasContext? context)
    {
        if (_context is { } previous)
        {
            previous.Vm.PropertyChanged -= OnVmPropertyChanged;
            previous.Vm.StructuralChangeRequested -= OnTimelineChanged;
            previous.Vm.RefreshVisualsRequested -= OnTimelineChanged;
            previous.VisualCache.ThumbnailsUpdated -= OnThumbnailsUpdated;
            previous.VisualCache.WaveformReady -= OnWaveformReady;
        }
        ClearThumbnailBitmaps();
        _requestedWaveforms.Clear();
        _hoveredClipId = null;
        _drag = null;
        _scrollX = 0;
        _scrollY = 0;

        _context = context;
        if (context is not null)
        {
            context.Vm.PropertyChanged += OnVmPropertyChanged;
            context.Vm.StructuralChangeRequested += OnTimelineChanged;
            context.Vm.RefreshVisualsRequested += OnTimelineChanged;
            context.VisualCache.ThumbnailsUpdated += OnThumbnailsUpdated;
            context.VisualCache.WaveformReady += OnWaveformReady;
        }

        UpdateScrollBarRanges();
        RequestRedraw();
    }

    private void OnVmPropertyChanged(object? sender, PropertyChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(() =>
        {
            if (e.PropertyName is nameof(TimelineEditorViewModel.ActiveTimelineId))
            {
                _scrollX = 0;
                _scrollY = 0;
                UpdateScrollBarRanges();
            }
            RequestRedraw();
        });

    private void OnTimelineChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(() =>
    {
        UpdateScrollBarRanges();
        RequestRedraw();
    });

    private void OnThumbnailsUpdated(object? sender, ThumbnailsUpdatedEventArgs e) => DispatcherQueue.TryEnqueue(RequestRedraw);

    private void OnWaveformReady(object? sender, WaveformReadyEventArgs e) => DispatcherQueue.TryEnqueue(RequestRedraw);

    private void RequestRedraw()
    {
        if (Canvas.ReadyToDraw)
        {
            Canvas.Invalidate();
        }
    }

    // MARK: - Geometry / coordinate space

    private TimelineGeometry BuildGeometry()
    {
        var heights = Vm?.Timeline.Tracks.Select(t => t.DisplayHeight).ToArray() ?? [];
        return new TimelineGeometry(_pixelsPerFrame, heights, TimelineGeometry.Layout.HeaderWidth);
    }

    private double ScreenXForFrame(TimelineGeometry geo, int frame) => geo.XForFrame(frame) - _scrollX;

    private double DocXForScreen(double screenX) => screenX + _scrollX;

    private double ScreenY(double docY) => docY - _scrollY;

    private double DocYForScreen(double screenY) => screenY + _scrollY;

    /// Viewport width/height of the scrollable content area (excludes the header column / ruler
    /// band, which render as fixed overlays — see TimelineCanvasControl.Rendering.cs).
    private double ContentViewportWidth => Math.Max(0, Canvas.ActualWidth - TimelineGeometry.Layout.HeaderWidth);

    private double ContentViewportHeight => Math.Max(0, Canvas.ActualHeight - TimelineGeometry.Layout.RulerHeight);

    private double TotalContentWidth(TimelineGeometry geo)
    {
        var framesWidth = (Vm?.Timeline.TotalFrames ?? 0) * _pixelsPerFrame;
        return Math.Max(ContentViewportWidth, framesWidth + ContentViewportWidth * 0.5);
    }

    private double TotalContentHeight(TimelineGeometry geo)
    {
        var tracksBottom = geo.TrackCount == 0
            ? TimelineGeometry.Layout.DropZoneHeight
            : geo.TrackY(geo.TrackCount - 1) + geo.TrackHeight(geo.TrackCount - 1) - TimelineGeometry.Layout.RulerHeight;
        return Math.Max(ContentViewportHeight, tracksBottom);
    }

    private void UpdateScrollBarRanges()
    {
        var geo = BuildGeometry();
        var maxX = Math.Max(0, TotalContentWidth(geo) - ContentViewportWidth);
        var maxY = Math.Max(0, TotalContentHeight(geo) - ContentViewportHeight);
        _scrollX = Math.Clamp(_scrollX, 0, maxX);
        _scrollY = Math.Clamp(_scrollY, 0, maxY);

        HorizontalScrollBar.Maximum = maxX;
        HorizontalScrollBar.ViewportSize = ContentViewportWidth;
        HorizontalScrollBar.LargeChange = Math.Max(1, ContentViewportWidth * 0.9);
        HorizontalScrollBar.Value = _scrollX;
        HorizontalScrollBar.Visibility = maxX > 0 ? Visibility.Visible : Visibility.Collapsed;

        VerticalScrollBar.Maximum = maxY;
        VerticalScrollBar.ViewportSize = ContentViewportHeight;
        VerticalScrollBar.LargeChange = Math.Max(1, ContentViewportHeight * 0.9);
        VerticalScrollBar.Value = _scrollY;
        VerticalScrollBar.Visibility = maxY > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Canvas_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        UpdateScrollBarRanges();
        RequestRedraw();
    }

    private void HorizontalScrollBar_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        _scrollX = e.NewValue;
        RequestRedraw();
    }

    private void VerticalScrollBar_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        _scrollY = e.NewValue;
        RequestRedraw();
    }

    private void SetLocalSnapX(double? x)
    {
        if (_localSnapX == x)
        {
            return;
        }
        _localSnapX = x;
        RequestRedraw();
    }

    private void SetExternalSnapX(double? x)
    {
        if (_externalSnapX == x)
        {
            return;
        }
        _externalSnapX = x;
        RequestRedraw();
    }

    private void SetHoveredClip(string? id)
    {
        if (_hoveredClipId == id)
        {
            return;
        }
        _hoveredClipId = id;
        RequestRedraw();
    }

    private void ClearThumbnailBitmaps()
    {
        foreach (var (_, bitmaps) in _thumbnailBitmaps.Values)
        {
            foreach (var bitmap in bitmaps)
            {
                bitmap.Dispose();
            }
        }
        _thumbnailBitmaps.Clear();
    }

    private void Canvas_CreateResources(Microsoft.Graphics.Canvas.UI.Xaml.CanvasControl sender, Microsoft.Graphics.Canvas.UI.CanvasCreateResourcesEventArgs args) =>
        ClearThumbnailBitmaps();

    private void Canvas_PointerExited(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        SetHoveredClip(null);
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.Arrow);
    }
}
