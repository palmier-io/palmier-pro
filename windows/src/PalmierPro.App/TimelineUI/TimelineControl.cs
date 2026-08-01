using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using PalmierPro.Core;
using PalmierPro.Core.Models;
using PalmierPro.Core.Playback;
using Windows.Foundation;
using Windows.System;
using Windows.UI;

namespace PalmierPro.App.TimelineUI;

/// <summary>What the user is currently dragging on the timeline.</summary>
internal enum TimelineDragKind
{
    None,
    ScrubPlayhead,
    MoveClip,
    TrimLeft,
    TrimRight,
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

    private readonly CanvasControl _canvas;

    public PalmierPro.Core.Models.Timeline? Timeline { get; private set; }
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
        KeyDown += OnKeyDown;
        SizeChanged += (_, _) => _canvas.Invalidate();
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
            session.FillRectangle(0, (float)top, (float)viewWidth, (float)height,
                Color.FromArgb(255, 26, 26, 26));
            session.DrawLine(0, (float)(top + height), (float)viewWidth, (float)(top + height),
                Color.FromArgb(40, 255, 255, 255));

            foreach (var clip in track.Clips)
            {
                DrawClip(session, geometry, trackIndex, clip);
            }
        }

        DrawRuler(session, geometry, viewWidth);
        DrawPlayhead(session, geometry);
        DrawSnapIndicator(session, geometry);
    }

    private void DrawClip(CanvasDrawingSession session, TimelineGeometry geometry, int trackIndex, Clip clip)
    {
        var isDragged = _dragClip?.Id == clip.Id && _drag is TimelineDragKind.MoveClip
            or TimelineDragKind.TrimLeft or TimelineDragKind.TrimRight;
        var startFrame = isDragged ? _dragPreviewStart : clip.StartFrame;
        var durationFrames = isDragged ? _dragPreviewDuration : clip.DurationFrames;

        var x = (float)(geometry.XForFrame(startFrame) - ScrollX);
        var width = (float)(durationFrames * ZoomScale);
        var top = (float)(geometry.TrackTop(trackIndex) + TimelineGeometry.ClipGutter);
        var height = (float)(geometry.TrackHeight(trackIndex) - 2 * TimelineGeometry.ClipGutter);
        if (x + width < 0 || x > _canvas.ActualWidth) return;

        var color = ClipColor(clip.MediaType);
        session.FillRoundedRectangle(x, top, Math.Max(1, width), height, 4, 4, color);

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
            var x = (float)(geometry.XForFrame(frame) - ScrollX);
            session.DrawLine(x, 16, x, 24, TickColor);
            session.DrawText(TimelineRulerMath.FormatTimecode(frame, fps), x + 3, 2, LabelColor, format);

            for (var s = 1; s < subdivisions; s++)
            {
                var minorX = (float)(geometry.XForFrame(frame + majorFrames * s / subdivisions) - ScrollX);
                session.DrawLine(minorX, 20, minorX, 24, TickColor);
            }
        }
    }

    private void DrawPlayhead(CanvasDrawingSession session, TimelineGeometry geometry)
    {
        var x = (float)(geometry.XForFrame(PlayheadFrame) - ScrollX);
        if (x < 0 || x > _canvas.ActualWidth) return;
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
        var x = (float)(geometry.XForFrame(frame) - ScrollX);
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
        if (Geometry is not { } geometry || Timeline is null) return;
        var point = e.GetCurrentPoint(_canvas).Position;
        var documentX = point.X + ScrollX;
        _canvas.CapturePointer(e.Pointer);

        if (point.Y < TimelineGeometry.RulerHeight)
        {
            _drag = TimelineDragKind.ScrubPlayhead;
            UpdateScrub(documentX, geometry, final: false);
            return;
        }

        var hit = geometry.HitTestClip(documentX, point.Y);
        if (hit is null)
        {
            if (SelectedClipIds.Count > 0)
            {
                SelectedClipIds.Clear();
                SelectionChanged?.Invoke();
                _canvas.Invalidate();
            }
            return;
        }

        var (trackIndex, clip) = hit.Value;
        var shift = e.KeyModifiers.HasFlag(VirtualKeyModifiers.Shift);
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

        if (localX <= TrimHandleWidth) _drag = TimelineDragKind.TrimLeft;
        else if (localX >= rect.Width - TrimHandleWidth) _drag = TimelineDragKind.TrimRight;
        else _drag = TimelineDragKind.MoveClip;
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_drag == TimelineDragKind.None || Geometry is not { } geometry) return;
        var point = e.GetCurrentPoint(_canvas).Position;
        var documentX = point.X + ScrollX;

        switch (_drag)
        {
            case TimelineDragKind.ScrubPlayhead:
                UpdateScrub(documentX, geometry, final: false);
                break;
            case TimelineDragKind.MoveClip:
                UpdateMovePreview(documentX, geometry);
                break;
            case TimelineDragKind.TrimLeft:
            case TimelineDragKind.TrimRight:
                UpdateTrimPreview(documentX, geometry);
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
        var documentX = point.X + ScrollX;

        switch (drag)
        {
            case TimelineDragKind.ScrubPlayhead:
                UpdateScrub(documentX, geometry, final: true);
                break;
            case TimelineDragKind.MoveClip or TimelineDragKind.TrimLeft or TimelineDragKind.TrimRight
                when _dragClip is not null:
                var changed = _dragPreviewStart != _dragOriginalStart
                    || _dragPreviewDuration != _dragOriginalDuration;
                if (changed)
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
            var (scale, scrollX) = TimelineZoom.ApplyZoom(
                ZoomScale, factor, minScale, point.Position.X + ScrollX, point.Position.X);
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
        if (e.Key is VirtualKey.Delete or VirtualKey.Back && SelectedClipIds.Count > 0)
        {
            DeleteRequested?.Invoke([.. SelectedClipIds]);
            e.Handled = true;
        }
    }

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
}

/// <summary>A completed drag gesture, forwarded to the domain edit layer.</summary>
public sealed record ClipEditRequest(
    string ClipId, int TrackIndex, int NewStartFrame, int NewDurationFrames, int NewTrimStartFrame);
