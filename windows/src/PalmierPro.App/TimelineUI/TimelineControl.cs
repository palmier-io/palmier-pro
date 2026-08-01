using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using PalmierPro.App.Editor;
using PalmierPro.Core;
using PalmierPro.Core.Editing;
using PalmierPro.Core.Models;
using PalmierPro.Core.Playback;
using PalmierPro.Media.Audio;
using PalmierPro.Media.Caches;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.Storage;
using Windows.System;
using Windows.UI;

namespace PalmierPro.App.TimelineUI;

/// <summary>What the user is currently dragging on the timeline.</summary>
internal enum TimelineDragKind
{
    None,
    ScrubPlayhead,
    MoveClip,
    SlipClip,
    TrimLeft,
    TrimRight,
    Marquee,
    ResizeTrack,
}

public enum TrackToggle
{
    Mute,
    Hidden,
    SyncLock,
}

/// <summary>Active edit tool: pointer (V), razor (C).</summary>
public enum TimelineTool
{
    Pointer,
    Razor,
}

/// <summary>
/// Win2D timeline: ruler, tracks, clips, selection, playhead, snapping. The Mac app
/// draws with CGContext in an NSView; this is the equivalent CanvasControl port.
/// Edit mutations are delegated to callbacks so the domain layer stays the single
/// source of truth.
/// </summary>
public sealed class TimelineControl : UserControl
{
    private const double TrimHandleWidth = 4;
    private const float HeaderWidth = 100;
    private const double ResizeHandleZone = 6;

    private readonly CanvasControl _canvas;

    public PalmierPro.Core.Models.Timeline? Timeline { get; private set; }

    /// <summary>Optional visual cache; clips fall back to solid fills when absent.</summary>
    public MediaVisualCache? VisualCache { get; set; }
    public double ZoomScale { get; private set; } = EditorDefaults.PixelsPerFrame;
    public double ScrollX { get; private set; }
    public int PlayheadFrame { get; private set; }
    public HashSet<string> SelectedClipIds { get; } = [];

    /// <summary>Raised as the user scrubs the ruler (interactive) and on release (exact).</summary>
    public event Action<int, bool>? ScrubRequested;
    /// <summary>Raised after a move/trim drag completes: (clipId, targetTrackIndex, newStart, newDuration, newTrimStart).</summary>
    public event Action<ClipEditRequest>? ClipEditRequested;
    public event Action? SelectionChanged;
    public event Action<IReadOnlyList<string>>? DeleteRequested;
    /// <summary>Raised on razor click: (clipId, frame to split at).</summary>
    public event Action<string, int>? SplitRequested;
    /// <summary>Raised when a Shift-trim (ripple) drag completes: (clipId, edge, edge delta in frames).</summary>
    public event Action<string, TrimEdge, int>? RippleTrimRequested;
    /// <summary>Raised on Ctrl-drag body release: slip source by delta frames.</summary>
    public event Action<string, int>? SlipRequested;
    /// <summary>Raised on Alt-drag release: cloned placements (clipId, trackIndex, frame).</summary>
    public event Action<IReadOnlyList<(string ClipId, int ToTrack, int ToFrame)>>? DuplicateRequested;
    /// <summary>Raised on Shift+Delete with clips selected.</summary>
    public event Action<IReadOnlyList<string>>? RippleDeleteRequested;
    /// <summary>Raised on Shift+Delete with a gap selected: (trackIndex, gap).</summary>
    public event Action<int, FrameRange>? GapRippleDeleteRequested;
    /// <summary>Raised when a header toggle is clicked.</summary>
    public event Action<int, TrackToggle>? TrackToggleRequested;
    /// <summary>Raised when a header height-resize drag completes.</summary>
    public event Action<int, double>? TrackResizeRequested;
    /// <summary>Raised on right-click over a clip: (clipId, frame, position in control coordinates).</summary>
    public event Action<string, int, Point>? ClipContextMenuRequested;
    /// <summary>Raised on right-click over a track header: (trackIndex, position in control coordinates).</summary>
    public event Action<int, Point>? TrackContextMenuRequested;
    /// <summary>Raised when media library items or files are dropped onto the timeline.</summary>
    public event Action<TimelineMediaDrop>? MediaDropRequested;

    public TimelineTool Tool { get; set; } = TimelineTool.Pointer;
    public (int TrackIndex, FrameRange Range)? SelectedGap { get; private set; }

    private TimelineDragKind _drag = TimelineDragKind.None;
    private Clip? _dragClip;
    private int _dragTrackIndex;
    private double _dragStartX;
    private int _dragOriginalStart;
    private int _dragOriginalDuration;
    private int _dragOriginalTrimStart;
    private int _dragPreviewStart;
    private int _dragPreviewDuration;
    private readonly SnapState _snapState = new();
    private int? _snapIndicatorFrame;
    private Point _marqueeStart;
    private Point _marqueeEnd;
    private bool _marqueeAdditive;
    private bool _dragIsDuplicate;
    private bool _dragIsRipple;
    private int _resizeTrackIndex = -1;
    private double _resizeOriginalHeight;
    private double _resizeStartY;

    public TimelineControl()
    {
        _canvas = new CanvasControl();
        _canvas.Draw += OnDraw;
        Content = _canvas;
        IsTabStop = true;

        _canvas.PointerPressed += OnPointerPressed;
        _canvas.PointerMoved += OnPointerMoved;
        _canvas.PointerReleased += OnPointerReleased;
        _canvas.PointerWheelChanged += OnPointerWheel;
        // Canvas often holds focus after a click — listen on both.
        KeyDown += OnKeyDown;
        _canvas.KeyDown += OnKeyDown;
        _canvas.IsTabStop = true;
        SizeChanged += (_, _) => _canvas.Invalidate();

        // Drop only on the canvas — registering the UserControl too double-fires PlaceClip
        // and creates a second linked audio track for one video drop.
        _canvas.AllowDrop = true;
        _canvas.DragOver += OnDragOver;
        _canvas.DragLeave += OnDragLeave;
        _canvas.Drop += OnDrop;
    }

    public void SetTimeline(PalmierPro.Core.Models.Timeline? timeline)
    {
        Timeline = timeline;
        _canvas.Invalidate();
    }

    public void SetPlayhead(int frame)
    {
        if (frame == PlayheadFrame) return;
        PlayheadFrame = frame;
        _canvas.Invalidate();
    }

    public void Refresh() => _canvas.Invalidate();

    public void ClearSelection()
    {
        SelectedClipIds.Clear();
        SelectedGap = null;
        SelectionChanged?.Invoke();
        _canvas.Invalidate();
    }

    /// <summary>Drops converted Win2D bitmaps for an asset (call when its visuals change).</summary>
    public void InvalidateMediaVisuals(string mediaRef)
    {
        if (_filmstripBitmaps.Remove(mediaRef, out var tiles))
            foreach (var tile in tiles) tile?.Dispose();
        if (_stillBitmaps.Remove(mediaRef, out var still)) still?.Dispose();
        _canvas.Invalidate();
    }

    private TimelineGeometry? Geometry
        => Timeline is null ? null : new TimelineGeometry(Timeline, ZoomScale);

    // MARK: - Drawing

    private static readonly Color TrackBackground = Color.FromArgb(255, 22, 22, 22);
    private static readonly Color RulerBackground = Color.FromArgb(255, 16, 16, 16);
    private static readonly Color TickColor = Color.FromArgb(120, 255, 255, 255);
    private static readonly Color LabelColor = Color.FromArgb(158, 255, 255, 255);
    private static readonly Color PlayheadColor = Color.FromArgb(255, 255, 69, 58);
    private static readonly Color SnapColor = Color.FromArgb(230, 250, 200, 60);
    private static readonly Color SelectionBorder = Colors.White;

    private static Color ClipColor(ClipType type) => type switch
    {
        ClipType.Video => Color.FromArgb(255, 0x1D, 0x58, 0x78),
        ClipType.Audio => Color.FromArgb(255, 0x2E, 0x77, 0x65),
        ClipType.Image or ClipType.Text => Color.FromArgb(255, 0x71, 0x54, 0x86),
        ClipType.Lottie => Color.FromArgb(255, 0xA0, 0x78, 0x22),
        ClipType.Sequence => Color.FromArgb(255, 0xB9, 0xB2, 0x9A),
        _ => Color.FromArgb(255, 0x44, 0x44, 0x44),
    };

    private void OnDraw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        var session = args.DrawingSession;
        session.Clear(TrackBackground);
        if (Geometry is not { } geometry || Timeline is null) return;

        var viewWidth = sender.ActualWidth;

        for (var trackIndex = 0; trackIndex < Timeline.Tracks.Count; trackIndex++)
        {
            var track = Timeline.Tracks[trackIndex];
            var top = geometry.TrackTop(trackIndex);
            var height = geometry.TrackHeight(trackIndex);
            session.FillRectangle(HeaderWidth, (float)top, (float)viewWidth, (float)height,
                Color.FromArgb(255, 26, 26, 26));
            session.DrawLine(HeaderWidth, (float)(top + height), (float)viewWidth, (float)(top + height),
                Color.FromArgb(40, 255, 255, 255));

            foreach (var clip in track.Clips)
            {
                DrawClip(session, geometry, trackIndex, clip);
            }
        }

        DrawGapSelection(session, geometry);
        DrawRuler(session, geometry, viewWidth);
        DrawTrackHeaders(session, geometry);
        DrawPlayhead(session, geometry);
        DrawSnapIndicator(session, geometry);
        DrawMarquee(session);
    }

    private void DrawGapSelection(CanvasDrawingSession session, TimelineGeometry geometry)
    {
        if (SelectedGap is not { } gap || gap.TrackIndex >= Timeline!.Tracks.Count) return;
        var x = (float)(geometry.XForFrame(gap.Range.Start) - ScrollX + HeaderWidth);
        var width = (float)(gap.Range.Length * ZoomScale);
        var top = (float)geometry.TrackTop(gap.TrackIndex);
        var height = (float)geometry.TrackHeight(gap.TrackIndex);
        session.FillRectangle(x, top, width, height, Color.FromArgb(50, 255, 255, 255));
        session.DrawRectangle(x, top, width, height, Color.FromArgb(160, 255, 255, 255), 1f);
    }

    private void DrawTrackHeaders(CanvasDrawingSession session, TimelineGeometry geometry)
    {
        session.FillRectangle(0, 0, HeaderWidth, (float)_canvas.ActualHeight, RulerBackground);
        session.DrawLine(HeaderWidth, 0, HeaderWidth, (float)_canvas.ActualHeight,
            Color.FromArgb(70, 255, 255, 255));

        var nameFormat = new CanvasTextFormat { FontSize = 11, WordWrapping = CanvasWordWrapping.NoWrap };
        var iconFormat = new CanvasTextFormat
        {
            FontSize = 12,
            FontFamily = "Segoe MDL2 Assets",
            HorizontalAlignment = CanvasHorizontalAlignment.Center,
            VerticalAlignment = CanvasVerticalAlignment.Center,
        };

        var videoNumber = 0;
        var audioNumber = 0;
        for (var trackIndex = 0; trackIndex < Timeline!.Tracks.Count; trackIndex++)
        {
            var track = Timeline.Tracks[trackIndex];
            var top = (float)geometry.TrackTop(trackIndex);
            var height = (float)geometry.TrackHeight(trackIndex);

            session.FillRectangle(0, top, 3, height, ClipColor(track.Type));
            session.DrawLine(0, top + height, HeaderWidth, top + height, Color.FromArgb(40, 255, 255, 255));

            var name = track.Type == ClipType.Audio
                ? $"Audio {++audioNumber}"
                : $"Video {++videoNumber}";
            session.DrawText(name, 8, top + 4, LabelColor, nameFormat);

            var (toggleRect, syncRect) = HeaderIconRects(top, height);
            var toggleGlyph = track.Type == ClipType.Audio
                ? (track.Muted ? "\uE74F" : "\uE767")   // MuteVolume / Volume
                : (track.Hidden ? "\uED1A" : "\uE7B3"); // Hide / RedEye
            var toggleActive = track.Type == ClipType.Audio ? track.Muted : track.Hidden;
            session.DrawText(toggleGlyph, toggleRect,
                toggleActive ? PlayheadColor : LabelColor, iconFormat);
            session.DrawText("\uE71B", syncRect,       // Link
                track.SyncLocked ? LabelColor : Color.FromArgb(70, 255, 255, 255), iconFormat);
        }
    }

    private static (Rect Toggle, Rect Sync) HeaderIconRects(float trackTop, float trackHeight)
    {
        var y = trackTop + trackHeight - 20;
        return (new Rect(HeaderWidth - 44, y, 18, 16), new Rect(HeaderWidth - 24, y, 18, 16));
    }

    private void DrawMarquee(CanvasDrawingSession session)
    {
        if (_drag != TimelineDragKind.Marquee) return;
        var x = (float)(Math.Min(_marqueeStart.X, _marqueeEnd.X) - ScrollX + HeaderWidth);
        var y = (float)Math.Min(_marqueeStart.Y, _marqueeEnd.Y);
        var width = (float)Math.Abs(_marqueeEnd.X - _marqueeStart.X);
        var height = (float)Math.Abs(_marqueeEnd.Y - _marqueeStart.Y);
        session.FillRectangle(x, y, width, height, Color.FromArgb(30, 255, 255, 255));
        var style = new Microsoft.Graphics.Canvas.Geometry.CanvasStrokeStyle
        {
            DashStyle = Microsoft.Graphics.Canvas.Geometry.CanvasDashStyle.Dash,
        };
        session.DrawRectangle(x, y, width, height, Color.FromArgb(160, 255, 255, 255), 1f, style);
    }

    private void DrawClip(CanvasDrawingSession session, TimelineGeometry geometry, int trackIndex, Clip clip)
    {
        // Alt-duplicate drags leave the original in place and draw a ghost separately.
        var isDragged = !_dragIsDuplicate && _dragClip?.Id == clip.Id && _drag is TimelineDragKind.MoveClip
            or TimelineDragKind.TrimLeft or TimelineDragKind.TrimRight;
        var startFrame = isDragged ? _dragPreviewStart : clip.StartFrame;
        var durationFrames = isDragged ? _dragPreviewDuration : clip.DurationFrames;

        var x = (float)(geometry.XForFrame(startFrame) - ScrollX + HeaderWidth);
        var width = (float)(durationFrames * ZoomScale);
        var top = (float)(geometry.TrackTop(trackIndex) + TimelineGeometry.ClipGutter);
        var height = (float)(geometry.TrackHeight(trackIndex) - 2 * TimelineGeometry.ClipGutter);
        if (x + width < HeaderWidth || x > _canvas.ActualWidth) return;

        if (_dragIsDuplicate && _dragClip?.Id == clip.Id && _drag == TimelineDragKind.MoveClip)
        {
            var ghostX = (float)(geometry.XForFrame(_dragPreviewStart) - ScrollX + HeaderWidth);
            session.FillRoundedRectangle(ghostX, top, Math.Max(1, width), height, 4, 4,
                Color.FromArgb(90, 255, 255, 255));
        }

        var color = ClipColor(clip.MediaType);
        session.FillRoundedRectangle(x, top, Math.Max(1, width), height, 4, 4, color);

        if (width >= 8)
        {
            using var clipLayer = session.CreateLayer(1f,
                Microsoft.Graphics.Canvas.Geometry.CanvasGeometry.CreateRoundedRectangle(
                    session, x, top, width, height, 4, 4));
            switch (clip.MediaType)
            {
                case ClipType.Video:
                    DrawFilmstrip(session, clip, x, top, width, height);
                    break;
                case ClipType.Image:
                    DrawImageStill(session, clip, x, top, width, height);
                    break;
                case ClipType.Audio:
                    DrawWaveform(session, clip, x, top, width, height);
                    break;
            }
        }

        var selected = SelectedClipIds.Contains(clip.Id);
        if (width >= 8)
        {
            session.DrawRoundedRectangle(x, top, width, height, 4, 4,
                selected ? SelectionBorder : Color.FromArgb(60, 255, 255, 255),
                selected ? 2f : 1f);
        }

        if (width >= 56 || (selected && width >= 32))
        {
            var name = clip.MediaType == ClipType.Text
                ? clip.TextContent ?? "Text"
                : clip.MediaRef;
            session.DrawText(name, x + 6, top + 2, LabelColor, new CanvasTextFormat
            {
                FontSize = 11,
                WordWrapping = CanvasWordWrapping.NoWrap,
            });
        }
    }

    // MARK: - Media visuals

    private readonly Dictionary<string, CanvasBitmap?[]> _filmstripBitmaps = [];
    private readonly Dictionary<string, CanvasBitmap?> _stillBitmaps = [];
    private const int MaxFilmstripTilesPerClip = 200;

    private void DrawFilmstrip(
        CanvasDrawingSession session, Clip clip,
        float x, float top, float width, float height)
    {
        if (VisualCache?.FilmstripFor(clip.MediaRef) is not { } strip || strip.Tiles.Count == 0) return;

        if (!_filmstripBitmaps.TryGetValue(clip.MediaRef, out var converted)
            || converted.Length != strip.Tiles.Count)
        {
            converted = new CanvasBitmap?[strip.Tiles.Count];
            _filmstripBitmaps[clip.MediaRef] = converted;
        }

        var fps = Math.Max(1, Timeline!.Fps);
        var tileWidth = (float)(height * strip.TileWidth / Math.Max(1, strip.TileHeight));
        if (tileWidth < 1) return;
        var tileInterval = strip.Times.Count > 1 ? strip.Times[1] - strip.Times[0] : 1.0;
        var drawn = 0;

        for (var tileX = x; tileX < x + width && drawn < MaxFilmstripTilesPerClip; tileX += tileWidth, drawn++)
        {
            if (tileX + tileWidth < 0) continue;
            if (tileX > _canvas.ActualWidth) break;
            var timelineOffsetFrames = (tileX - x) / ZoomScale;
            var sourceSeconds = (clip.TrimStartFrame + timelineOffsetFrames * clip.Speed) / fps;
            var index = Math.Clamp((int)Math.Round(sourceSeconds / Math.Max(0.001, tileInterval)),
                0, strip.Tiles.Count - 1);
            var bitmap = ConvertedTile(strip, converted, index);
            if (bitmap is null) continue;
            session.DrawImage(bitmap, new Rect(tileX, top, tileWidth, height));
        }
    }

    private void DrawImageStill(
        CanvasDrawingSession session, Clip clip,
        float x, float top, float width, float height)
    {
        if (VisualCache?.ImageStillFor(clip.MediaRef) is not { } still) return;
        if (!_stillBitmaps.TryGetValue(clip.MediaRef, out var bitmap))
        {
            bitmap = ToCanvasBitmap(still);
            _stillBitmaps[clip.MediaRef] = bitmap;
        }
        if (bitmap is null) return;

        // Single thumbnail tiled across the clip, like the Mac image clip rendering.
        var tileWidth = (float)(height * still.Width / Math.Max(1, still.Height));
        for (var tileX = x; tileX < x + width; tileX += tileWidth)
        {
            if (tileX + tileWidth < 0) continue;
            if (tileX > _canvas.ActualWidth) break;
            session.DrawImage(bitmap, new Rect(tileX, top, tileWidth, height));
        }
    }

    private void DrawWaveform(
        CanvasDrawingSession session, Clip clip,
        float x, float top, float width, float height)
    {
        if (VisualCache?.WaveformFor(clip.MediaRef) is not { } samples || samples.Length == 0) return;
        var fps = Math.Max(1, Timeline!.Fps);
        var barColor = Color.FromArgb(170, 255, 255, 255);

        var firstColumn = (int)Math.Max(0, -x);
        var lastColumn = (int)Math.Min(width, _canvas.ActualWidth - x);
        for (var column = firstColumn; column < lastColumn; column++)
        {
            var timelineOffsetFrames = column / ZoomScale;
            var sourceSeconds = (clip.TrimStartFrame + timelineOffsetFrames * clip.Speed) / fps;
            var index = (int)(sourceSeconds * WaveformExtractor.SamplesPerSecond);
            if (index < 0 || index >= samples.Length) continue;
            // Samples are normalized dB distance from full scale: 0 = loud, 1 = silence.
            var loudness = 1f - Math.Clamp(samples[index], 0f, 1f);
            var barHeight = Math.Max(1f, loudness * (height - 4));
            var barTop = top + (height - barHeight) / 2f;
            session.DrawLine(x + column, barTop, x + column, barTop + barHeight, barColor, 1f);
        }
    }

    private CanvasBitmap? ConvertedTile(Filmstrip strip, CanvasBitmap?[] converted, int index)
    {
        if (converted[index] is { } existing) return existing;
        converted[index] = ToCanvasBitmap(strip.Tiles[index]);
        return converted[index];
    }

    private CanvasBitmap? ToCanvasBitmap(System.Drawing.Bitmap bitmap)
    {
        try
        {
            var rect = new System.Drawing.Rectangle(0, 0, bitmap.Width, bitmap.Height);
            var data = bitmap.LockBits(rect,
                System.Drawing.Imaging.ImageLockMode.ReadOnly,
                System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            try
            {
                var bytes = new byte[data.Stride * data.Height];
                System.Runtime.InteropServices.Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
                return CanvasBitmap.CreateFromBytes(
                    _canvas, bytes, bitmap.Width, bitmap.Height,
                    Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized);
            }
            finally
            {
                bitmap.UnlockBits(data);
            }
        }
        catch (Exception)
        {
            return null;
        }
    }

    private void DrawRuler(CanvasDrawingSession session, TimelineGeometry geometry, double viewWidth)
    {
        session.FillRectangle(0, 0, (float)viewWidth, (float)TimelineGeometry.RulerHeight, RulerBackground);
        session.DrawLine(0, (float)TimelineGeometry.RulerHeight, (float)viewWidth,
            (float)TimelineGeometry.RulerHeight, Color.FromArgb(60, 255, 255, 255));

        var fps = Math.Max(1, Timeline!.Fps);
        var majorFrames = TimelineRulerMath.MajorIntervalFrames(fps, ZoomScale);
        var subdivisions = TimelineRulerMath.MinorSubdivisions(majorFrames, ZoomScale);
        var firstFrame = Math.Max(0, geometry.FrameForX(ScrollX) / majorFrames * majorFrames);
        var lastFrame = geometry.FrameForX(ScrollX + viewWidth) + majorFrames;

        var format = new CanvasTextFormat { FontSize = 10, WordWrapping = CanvasWordWrapping.NoWrap };
        for (var frame = firstFrame; frame <= lastFrame; frame += majorFrames)
        {
            var x = (float)(geometry.XForFrame(frame) - ScrollX + HeaderWidth);
            if (x >= HeaderWidth)
            {
                session.DrawLine(x, 16, x, 24, TickColor);
                session.DrawText(TimelineRulerMath.FormatTimecode(frame, fps), x + 3, 2, LabelColor, format);
            }

            for (var s = 1; s < subdivisions; s++)
            {
                var minorX = (float)(geometry.XForFrame(frame + majorFrames * s / subdivisions)
                    - ScrollX + HeaderWidth);
                if (minorX >= HeaderWidth) session.DrawLine(minorX, 20, minorX, 24, TickColor);
            }
        }
    }

    private void DrawPlayhead(CanvasDrawingSession session, TimelineGeometry geometry)
    {
        var x = (float)(geometry.XForFrame(PlayheadFrame) - ScrollX + HeaderWidth);
        if (x < HeaderWidth || x > _canvas.ActualWidth) return;
        session.DrawLine(x, 0, x, (float)_canvas.ActualHeight, PlayheadColor, 1.5f);
        session.FillGeometry(
            Microsoft.Graphics.Canvas.Geometry.CanvasGeometry.CreatePolygon(session, [
                new System.Numerics.Vector2(x - 5, 0),
                new System.Numerics.Vector2(x + 5, 0),
                new System.Numerics.Vector2(x, 8),
            ]), PlayheadColor);
    }

    private void DrawSnapIndicator(CanvasDrawingSession session, TimelineGeometry geometry)
    {
        if (_snapIndicatorFrame is not { } frame) return;
        var x = (float)(geometry.XForFrame(frame) - ScrollX + HeaderWidth);
        if (x < HeaderWidth) return;
        var style = new Microsoft.Graphics.Canvas.Geometry.CanvasStrokeStyle
        {
            DashStyle = Microsoft.Graphics.Canvas.Geometry.CanvasDashStyle.Dash,
        };
        session.DrawLine(x, (float)TimelineGeometry.RulerHeight, x, (float)_canvas.ActualHeight,
            SnapColor, 1f, style);
    }

    // MARK: - Input

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        Focus(FocusState.Programmatic);
        _canvas.Focus(FocusState.Programmatic);
        if (Geometry is not { } geometry || Timeline is null) return;
        var point = e.GetCurrentPoint(_canvas).Position;
        var documentX = point.X - HeaderWidth + ScrollX;
        _canvas.CapturePointer(e.Pointer);

        if (point.X < HeaderWidth && point.Y >= TimelineGeometry.RulerHeight)
        {
            if (e.GetCurrentPoint(_canvas).Properties.IsRightButtonPressed
                && geometry.TrackIndexForY(point.Y) is { } rightTrack)
            {
                _canvas.ReleasePointerCaptures();
                TrackContextMenuRequested?.Invoke(rightTrack, point);
                return;
            }
            HandleHeaderPress(point, geometry);
            return;
        }

        if (point.Y < TimelineGeometry.RulerHeight)
        {
            _drag = TimelineDragKind.ScrubPlayhead;
            UpdateScrub(documentX, geometry, final: false);
            return;
        }

        var hit = geometry.HitTestClip(documentX, point.Y);
        var shift = e.KeyModifiers.HasFlag(VirtualKeyModifiers.Shift);
        var alt = e.KeyModifiers.HasFlag(VirtualKeyModifiers.Menu);
        var ctrl = e.KeyModifiers.HasFlag(VirtualKeyModifiers.Control);
        if (hit is null)
        {
            // Empty area: marquee on drag, gap selection on plain click (resolved at release).
            _drag = TimelineDragKind.Marquee;
            _marqueeAdditive = shift;
            _marqueeStart = new Point(documentX, point.Y);
            _marqueeEnd = _marqueeStart;
            if (!shift && SelectedClipIds.Count > 0)
            {
                SelectedClipIds.Clear();
                SelectionChanged?.Invoke();
            }
            if (SelectedGap is not null)
            {
                SelectedGap = null;
                SelectionChanged?.Invoke();
            }
            _canvas.Invalidate();
            return;
        }

        SelectedGap = null;
        var (trackIndex, clip) = hit.Value;

        if (e.GetCurrentPoint(_canvas).Properties.IsRightButtonPressed)
        {
            if (!SelectedClipIds.Contains(clip.Id)) SelectClip(clip, additive: false);
            _canvas.ReleasePointerCaptures();
            ClipContextMenuRequested?.Invoke(clip.Id, geometry.FrameForX(documentX), point);
            return;
        }

        if (Tool == TimelineTool.Razor)
        {
            var splitFrame = geometry.FrameForX(documentX);
            if (splitFrame > clip.StartFrame && splitFrame < clip.EndFrame)
                SplitRequested?.Invoke(clip.Id, splitFrame);
            return;
        }

        SelectClip(clip, additive: shift);

        var rect = geometry.ClipRect(trackIndex, clip);
        var localX = documentX - rect.X;
        _dragClip = clip;
        _dragTrackIndex = trackIndex;
        _dragStartX = documentX;
        _dragOriginalStart = clip.StartFrame;
        _dragOriginalDuration = clip.DurationFrames;
        _dragOriginalTrimStart = clip.TrimStartFrame;
        _dragPreviewStart = clip.StartFrame;
        _dragPreviewDuration = clip.DurationFrames;
        _snapState.CurrentlySnappedTo = null;
        _dragIsDuplicate = false;
        _dragIsRipple = false;

        if (localX <= TrimHandleWidth)
        {
            _drag = TimelineDragKind.TrimLeft;
            _dragIsRipple = shift;
        }
        else if (localX >= rect.Width - TrimHandleWidth)
        {
            _drag = TimelineDragKind.TrimRight;
            _dragIsRipple = shift;
        }
        else
        {
            if (ctrl && !alt)
                _drag = TimelineDragKind.SlipClip;
            else
            {
                _drag = TimelineDragKind.MoveClip;
                _dragIsDuplicate = alt;
            }
        }
    }

    private void HandleHeaderPress(Point point, TimelineGeometry geometry)
    {
        if (geometry.TrackIndexForY(point.Y) is not { } trackIndex)
        {
            // Between tracks: allow grabbing the resize zone below the last track edge.
            trackIndex = -1;
            for (var i = 0; i < Timeline!.Tracks.Count; i++)
            {
                var bottom = geometry.TrackTop(i) + geometry.TrackHeight(i);
                if (Math.Abs(point.Y - bottom) <= ResizeHandleZone) { trackIndex = i; break; }
            }
            if (trackIndex < 0) return;
            BeginTrackResize(trackIndex, point.Y);
            return;
        }

        var top = (float)geometry.TrackTop(trackIndex);
        var height = (float)geometry.TrackHeight(trackIndex);

        if (point.Y >= top + height - ResizeHandleZone)
        {
            BeginTrackResize(trackIndex, point.Y);
            return;
        }

        var (toggleRect, syncRect) = HeaderIconRects(top, height);
        if (toggleRect.Contains(point))
        {
            var track = Timeline!.Tracks[trackIndex];
            TrackToggleRequested?.Invoke(trackIndex,
                track.Type == ClipType.Audio ? TrackToggle.Mute : TrackToggle.Hidden);
        }
        else if (syncRect.Contains(point))
        {
            TrackToggleRequested?.Invoke(trackIndex, TrackToggle.SyncLock);
        }
    }

    private void BeginTrackResize(int trackIndex, double y)
    {
        _drag = TimelineDragKind.ResizeTrack;
        _resizeTrackIndex = trackIndex;
        _resizeOriginalHeight = Timeline!.Tracks[trackIndex].DisplayHeight;
        _resizeStartY = y;
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_drag == TimelineDragKind.None || Geometry is not { } geometry) return;
        var point = e.GetCurrentPoint(_canvas).Position;
        var documentX = point.X - HeaderWidth + ScrollX;

        switch (_drag)
        {
            case TimelineDragKind.ScrubPlayhead:
                UpdateScrub(documentX, geometry, final: false);
                break;
            case TimelineDragKind.MoveClip:
                UpdateMovePreview(documentX, geometry);
                break;
            case TimelineDragKind.SlipClip:
                // Body stays fixed; slip commits on release.
                break;
            case TimelineDragKind.TrimLeft:
            case TimelineDragKind.TrimRight:
                UpdateTrimPreview(documentX, geometry);
                break;
            case TimelineDragKind.Marquee:
                _marqueeEnd = new Point(documentX, point.Y);
                _canvas.Invalidate();
                break;
            case TimelineDragKind.ResizeTrack when _resizeTrackIndex >= 0:
                // Live preview only; the undoable commit happens on release.
                Timeline!.Tracks[_resizeTrackIndex].DisplayHeight = Math.Clamp(
                    _resizeOriginalHeight + (point.Y - _resizeStartY),
                    TrackSize.MinHeight, TrackSize.MaxHeight);
                _canvas.Invalidate();
                break;
        }
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        var drag = _drag;
        _drag = TimelineDragKind.None;
        _snapIndicatorFrame = null;
        _canvas.ReleasePointerCaptures();
        if (Geometry is not { } geometry) return;
        var point = e.GetCurrentPoint(_canvas).Position;
        var documentX = point.X - HeaderWidth + ScrollX;

        switch (drag)
        {
            case TimelineDragKind.ScrubPlayhead:
                UpdateScrub(documentX, geometry, final: true);
                break;
            case TimelineDragKind.Marquee:
                _marqueeEnd = new Point(documentX, point.Y);
                var movedDistance = Math.Abs(_marqueeEnd.X - _marqueeStart.X)
                    + Math.Abs(_marqueeEnd.Y - _marqueeStart.Y);
                if (movedDistance < 3) SelectGapAt(documentX, point.Y, geometry);
                else CommitMarquee(geometry);
                break;
            case TimelineDragKind.ResizeTrack when _resizeTrackIndex >= 0:
                var finalHeight = Timeline!.Tracks[_resizeTrackIndex].DisplayHeight;
                // Restore the live preview, then commit through the undoable operation.
                Timeline.Tracks[_resizeTrackIndex].DisplayHeight = _resizeOriginalHeight;
                if (Math.Abs(finalHeight - _resizeOriginalHeight) >= 0.5)
                    TrackResizeRequested?.Invoke(_resizeTrackIndex, finalHeight);
                _resizeTrackIndex = -1;
                break;
            case TimelineDragKind.SlipClip when _dragClip is not null:
                var slipDelta = (int)Math.Round((documentX - _dragStartX) / ZoomScale);
                if (slipDelta != 0) SlipRequested?.Invoke(_dragClip.Id, slipDelta);
                break;
            case TimelineDragKind.MoveClip when _dragClip is not null && _dragIsDuplicate:
                if (_dragPreviewStart != _dragOriginalStart)
                {
                    var delta = _dragPreviewStart - _dragOriginalStart;
                    var placements = new List<(string, int, int)>();
                    for (var trackIndex = 0; trackIndex < Timeline!.Tracks.Count; trackIndex++)
                    {
                        foreach (var clip in Timeline.Tracks[trackIndex].Clips)
                        {
                            if (SelectedClipIds.Contains(clip.Id))
                                placements.Add((clip.Id, trackIndex, Math.Max(0, clip.StartFrame + delta)));
                        }
                    }
                    if (placements.Count > 0) DuplicateRequested?.Invoke(placements);
                }
                break;
            case TimelineDragKind.MoveClip or TimelineDragKind.TrimLeft or TimelineDragKind.TrimRight
                when _dragClip is not null:
                var changed = _dragPreviewStart != _dragOriginalStart
                    || _dragPreviewDuration != _dragOriginalDuration;
                if (changed && _dragIsRipple && drag is TimelineDragKind.TrimLeft or TimelineDragKind.TrimRight)
                {
                    // Ripple trim: report the signed movement of the dragged edge.
                    var edge = drag == TimelineDragKind.TrimLeft ? TrimEdge.Left : TrimEdge.Right;
                    var edgeDelta = edge == TrimEdge.Left
                        ? _dragPreviewStart - _dragOriginalStart
                        : (_dragPreviewStart + _dragPreviewDuration)
                            - (_dragOriginalStart + _dragOriginalDuration);
                    if (edgeDelta != 0) RippleTrimRequested?.Invoke(_dragClip.Id, edge, edgeDelta);
                }
                else if (changed)
                {
                    var trimStart = drag == TimelineDragKind.TrimLeft
                        ? _dragOriginalTrimStart + (int)Math.Round(
                            (_dragPreviewStart - _dragOriginalStart) * _dragClip.Speed)
                        : _dragOriginalTrimStart;
                    ClipEditRequested?.Invoke(new ClipEditRequest(
                        _dragClip.Id, _dragTrackIndex,
                        _dragPreviewStart, _dragPreviewDuration, trimStart));
                }
                break;
        }
        _dragClip = null;
        _dragIsDuplicate = false;
        _dragIsRipple = false;
        _canvas.Invalidate();
    }

    private void SelectGapAt(double documentX, double y, TimelineGeometry geometry)
    {
        if (Timeline is null || geometry.TrackIndexForY(y) is not { } trackIndex) return;
        var frame = geometry.FrameForX(documentX);
        var track = Timeline.Tracks[trackIndex];

        var gapStart = 0;
        int? gapEnd = null;
        foreach (var clip in track.Clips.OrderBy(c => c.StartFrame))
        {
            if (clip.EndFrame <= frame)
            {
                gapStart = clip.EndFrame;
            }
            else if (clip.StartFrame > frame)
            {
                gapEnd = clip.StartFrame;
                break;
            }
            else
            {
                return; // Inside a clip; not a gap.
            }
        }
        // Trailing space isn't a closable gap.
        if (gapEnd is null) return;

        SelectedGap = (trackIndex, new FrameRange(gapStart, gapEnd.Value));
        SelectionChanged?.Invoke();
        _canvas.Invalidate();
    }

    private void OnPointerWheel(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(_canvas);
        var delta = point.Properties.MouseWheelDelta;
        if (e.KeyModifiers.HasFlag(VirtualKeyModifiers.Menu)
            || e.KeyModifiers.HasFlag(VirtualKeyModifiers.Control))
        {
            var factor = Math.Exp(delta / 120.0 * 0.12);
            var minScale = TimelineZoom.MinZoomScale(
                _canvas.ActualWidth,
                Timeline is null ? 0 : TimelineFrameRouter.DurationFrames(Timeline));
            var anchorViewportX = Math.Max(0, point.Position.X - HeaderWidth);
            var (scale, scrollX) = TimelineZoom.ApplyZoom(
                ZoomScale, factor, minScale, anchorViewportX + ScrollX, anchorViewportX);
            ZoomScale = scale;
            ScrollX = scrollX;
        }
        else
        {
            ScrollX = Math.Max(0, ScrollX - delta);
        }
        _canvas.Invalidate();
        e.Handled = true;
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Delete or VirtualKey.Back when IsShiftDown() && SelectedGap is { } gap:
                GapRippleDeleteRequested?.Invoke(gap.TrackIndex, gap.Range);
                SelectedGap = null;
                _canvas.Invalidate();
                e.Handled = true;
                break;
            case VirtualKey.Delete or VirtualKey.Back when IsShiftDown() && SelectedClipIds.Count > 0:
            {
                var ids = SelectedClipIds.ToArray();
                SelectedClipIds.Clear();
                RippleDeleteRequested?.Invoke(ids);
                SelectionChanged?.Invoke();
                _canvas.Invalidate();
                e.Handled = true;
                break;
            }
            case VirtualKey.Delete or VirtualKey.Back when SelectedClipIds.Count > 0:
            {
                var ids = SelectedClipIds.ToArray();
                SelectedClipIds.Clear();
                DeleteRequested?.Invoke(ids);
                SelectionChanged?.Invoke();
                _canvas.Invalidate();
                e.Handled = true;
                break;
            }
            case VirtualKey.V:
                Tool = TimelineTool.Pointer;
                e.Handled = true;
                break;
            case VirtualKey.C when !IsControlDown():
                Tool = TimelineTool.Razor;
                e.Handled = true;
                break;
            case VirtualKey.Escape:
                if (_drag != TimelineDragKind.None)
                {
                    if (_drag == TimelineDragKind.ResizeTrack && _resizeTrackIndex >= 0)
                    {
                        Timeline!.Tracks[_resizeTrackIndex].DisplayHeight = _resizeOriginalHeight;
                        _resizeTrackIndex = -1;
                    }
                    _drag = TimelineDragKind.None;
                    _dragClip = null;
                    _dragIsDuplicate = false;
                    _dragIsRipple = false;
                    _snapIndicatorFrame = null;
                    _canvas.ReleasePointerCaptures();
                }
                else if (SelectedClipIds.Count > 0 || SelectedGap is not null)
                {
                    SelectedClipIds.Clear();
                    SelectedGap = null;
                    SelectionChanged?.Invoke();
                }
                Tool = TimelineTool.Pointer;
                _canvas.Invalidate();
                e.Handled = true;
                break;
        }
    }

    private static bool IsControlDown()
        => Microsoft.UI.Input.InputKeyboardSource
            .GetKeyStateForCurrentThread(VirtualKey.Control)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private static bool IsShiftDown()
        => Microsoft.UI.Input.InputKeyboardSource
            .GetKeyStateForCurrentThread(VirtualKey.Shift)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private void UpdateScrub(double documentX, TimelineGeometry geometry, bool final)
    {
        var frame = geometry.FrameForX(documentX);
        PlayheadFrame = frame;
        ScrubRequested?.Invoke(frame, final);
        _canvas.Invalidate();
    }

    private void UpdateMovePreview(double documentX, TimelineGeometry geometry)
    {
        if (_dragClip is null || Timeline is null) return;
        var deltaFrames = (int)Math.Round((documentX - _dragStartX) / ZoomScale);
        var proposed = Math.Max(0, _dragOriginalStart + deltaFrames);

        var snap = TimelineSnap.Find(
            proposed,
            [0, _dragOriginalDuration],
            SnapTargets(excludeClipId: _dragClip.Id),
            ZoomScale, _snapState);
        if (snap is not null) proposed = Math.Max(0, snap.Frame - snap.ProbeOffset);
        _snapIndicatorFrame = snap?.Frame;

        _dragPreviewStart = proposed;
        _dragPreviewDuration = _dragOriginalDuration;
        _canvas.Invalidate();
    }

    private void UpdateTrimPreview(double documentX, TimelineGeometry geometry)
    {
        if (_dragClip is null) return;
        var frame = geometry.FrameForX(documentX);
        if (_drag == TimelineDragKind.TrimLeft)
        {
            var maxStart = _dragOriginalStart + _dragOriginalDuration - 1;
            var minStart = Math.Max(0,
                _dragOriginalStart - (int)Math.Round(_dragOriginalTrimStart / Math.Max(0.0001, _dragClip.Speed)));
            var newStart = Math.Clamp(frame, minStart, maxStart);
            _dragPreviewStart = newStart;
            _dragPreviewDuration = _dragOriginalStart + _dragOriginalDuration - newStart;
        }
        else
        {
            var minEnd = _dragOriginalStart + 1;
            var newEnd = Math.Max(frame, minEnd);
            _dragPreviewStart = _dragOriginalStart;
            _dragPreviewDuration = newEnd - _dragOriginalStart;
        }
        _canvas.Invalidate();
    }

    private List<(int Frame, bool IsPlayhead)> SnapTargets(string excludeClipId)
    {
        var targets = new List<(int, bool)> { (PlayheadFrame, true) };
        foreach (var track in Timeline!.Tracks)
        {
            foreach (var clip in track.Clips)
            {
                if (clip.Id == excludeClipId) continue;
                targets.Add((clip.StartFrame, false));
                targets.Add((clip.EndFrame, false));
            }
        }
        return targets;
    }

    private void CommitMarquee(TimelineGeometry geometry)
    {
        if (Timeline is null) return;
        var left = Math.Min(_marqueeStart.X, _marqueeEnd.X);
        var right = Math.Max(_marqueeStart.X, _marqueeEnd.X);
        var topY = Math.Min(_marqueeStart.Y, _marqueeEnd.Y);
        var bottomY = Math.Max(_marqueeStart.Y, _marqueeEnd.Y);

        var hitIds = new List<string>();
        for (var trackIndex = 0; trackIndex < Timeline.Tracks.Count; trackIndex++)
        {
            var trackTop = geometry.TrackTop(trackIndex);
            var trackBottom = trackTop + geometry.TrackHeight(trackIndex);
            if (trackBottom < topY || trackTop > bottomY) continue;
            foreach (var clip in Timeline.Tracks[trackIndex].Clips)
            {
                var clipLeft = geometry.XForFrame(clip.StartFrame);
                var clipRight = geometry.XForFrame(clip.EndFrame);
                if (clipRight >= left && clipLeft <= right) hitIds.Add(clip.Id);
            }
        }

        // Expand to link groups like the Mac marquee.
        var groups = Timeline.Tracks.SelectMany(t => t.Clips)
            .Where(c => hitIds.Contains(c.Id) && c.LinkGroupId is not null)
            .Select(c => c.LinkGroupId!)
            .ToHashSet();
        foreach (var clip in Timeline.Tracks.SelectMany(t => t.Clips))
        {
            if (clip.LinkGroupId is { } group && groups.Contains(group)) hitIds.Add(clip.Id);
        }

        if (!_marqueeAdditive) SelectedClipIds.Clear();
        foreach (var id in hitIds) SelectedClipIds.Add(id);
        SelectionChanged?.Invoke();
        _canvas.Invalidate();
    }

    private void SelectClip(Clip clip, bool additive)
    {
        // Link-group aware: selecting one linked partner selects the whole group.
        var groupIds = clip.LinkGroupId is { } linkId && Timeline is not null
            ? Timeline.Tracks.SelectMany(t => t.Clips)
                .Where(c => c.LinkGroupId == linkId)
                .Select(c => c.Id)
                .ToList()
            : [clip.Id];

        if (additive)
        {
            if (groupIds.All(SelectedClipIds.Contains))
                foreach (var id in groupIds) SelectedClipIds.Remove(id);
            else
                foreach (var id in groupIds) SelectedClipIds.Add(id);
        }
        else
        {
            SelectedClipIds.Clear();
            foreach (var id in groupIds) SelectedClipIds.Add(id);
        }
        SelectionChanged?.Invoke();
        _canvas.Invalidate();
    }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        if (Timeline is null || Geometry is null)
        {
            e.AcceptedOperation = DataPackageOperation.None;
            return;
        }

        var canText = e.DataView.Contains(StandardDataFormats.Text);
        var canFiles = e.DataView.Contains(StandardDataFormats.StorageItems);
        if (!canText && !canFiles)
        {
            e.AcceptedOperation = DataPackageOperation.None;
            return;
        }

        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.Caption = "Add to timeline";
        e.DragUIOverride.IsCaptionVisible = true;
        e.DragUIOverride.IsGlyphVisible = true;

        var point = e.GetPosition(_canvas);
        var documentX = point.X - HeaderWidth + ScrollX;
        if (documentX >= 0)
        {
            _snapIndicatorFrame = Geometry.FrameForX(documentX);
            _canvas.Invalidate();
        }
    }

    private void OnDragLeave(object sender, DragEventArgs e)
    {
        if (_snapIndicatorFrame is null) return;
        _snapIndicatorFrame = null;
        _canvas.Invalidate();
    }

    private async void OnDrop(object sender, DragEventArgs e)
    {
        e.Handled = true;
        _snapIndicatorFrame = null;
        _canvas.Invalidate();
        if (Timeline is null || Geometry is not { } geometry) return;

        var point = e.GetPosition(_canvas);
        var documentX = Math.Max(0, point.X - HeaderWidth + ScrollX);
        var frame = geometry.FrameForX(documentX);
        var trackIndex = geometry.TrackIndexForY(point.Y);

        var mediaRefs = new List<string>();
        var filePaths = new List<string>();

        try
        {
            if (e.DataView.Contains(StandardDataFormats.Text))
            {
                var text = await e.DataView.GetTextAsync();
                if (MediaDragPayload.TryDecode(text, out var refs))
                    mediaRefs.AddRange(refs);
            }

            if (e.DataView.Contains(StandardDataFormats.StorageItems))
            {
                var items = await e.DataView.GetStorageItemsAsync();
                foreach (var item in items.OfType<StorageFile>())
                {
                    if (ClipTypeExtensions.FromFileExtension(
                            Path.GetExtension(item.Path).TrimStart('.')) is not null)
                        filePaths.Add(item.Path);
                }
            }
        }
        catch
        {
            return;
        }

        if (mediaRefs.Count == 0 && filePaths.Count == 0) return;
        MediaDropRequested?.Invoke(new TimelineMediaDrop(mediaRefs, filePaths, frame, trackIndex));
    }
}

/// <summary>Payload for dropping media library items or Explorer files onto the timeline.</summary>
public readonly record struct TimelineMediaDrop(
    IReadOnlyList<string> MediaRefs,
    IReadOnlyList<string> FilePaths,
    int Frame,
    int? TrackIndex);


/// <summary>A completed drag gesture, forwarded to the domain edit layer.</summary>
public sealed record ClipEditRequest(
    string ClipId, int TrackIndex, int NewStartFrame, int NewDurationFrames, int NewTrimStartFrame);
