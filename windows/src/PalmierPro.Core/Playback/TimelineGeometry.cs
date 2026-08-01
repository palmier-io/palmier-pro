using PalmierPro.Core.Models;

namespace PalmierPro.Core.Playback;

/// <summary>
/// Shared timeline layout math mirroring the Mac TimelineGeometry: zoomScale is
/// pixels-per-frame, Y is top-down starting with the ruler and a drop zone, and each
/// track contributes its display height.
/// </summary>
public sealed class TimelineGeometry
{
    public const double RulerHeight = 24;
    public const double DropZoneHeight = 60;
    public const double ClipGutter = 2;
    public const double TrackHeaderWidth = 100;

    public Timeline Timeline { get; }
    public double PixelsPerFrame { get; }

    private readonly double[] _trackTops;

    public TimelineGeometry(Timeline timeline, double pixelsPerFrame)
    {
        Timeline = timeline;
        PixelsPerFrame = Math.Max(Zoom.Floor, pixelsPerFrame);
        _trackTops = new double[timeline.Tracks.Count];
        var y = RulerHeight + DropZoneHeight;
        for (var i = 0; i < timeline.Tracks.Count; i++)
        {
            _trackTops[i] = y;
            y += timeline.Tracks[i].DisplayHeight;
        }
        ContentHeight = y + DropZoneHeight;
    }

    public double ContentHeight { get; }

    public double ContentWidth(double visibleWidth)
        => PixelsPerFrame * TimelineFrameRouter.DurationFrames(Timeline) + 0.5 * visibleWidth;

    public double XForFrame(int frame) => frame * PixelsPerFrame;

    public int FrameForX(double x) => Math.Max(0, (int)(x / PixelsPerFrame));

    public double TrackTop(int trackIndex) => _trackTops[trackIndex];

    public double TrackHeight(int trackIndex) => Timeline.Tracks[trackIndex].DisplayHeight;

    public int? TrackIndexForY(double y)
    {
        for (var i = 0; i < _trackTops.Length; i++)
        {
            if (y >= _trackTops[i] && y < _trackTops[i] + TrackHeight(i)) return i;
        }
        return null;
    }

    public (double X, double Y, double Width, double Height) ClipRect(int trackIndex, Clip clip)
    {
        var x = XForFrame(clip.StartFrame);
        var width = clip.DurationFrames * PixelsPerFrame;
        var y = TrackTop(trackIndex) + ClipGutter;
        var height = TrackHeight(trackIndex) - 2 * ClipGutter;
        return (x, y, width, height);
    }

    public (int TrackIndex, Clip Clip)? HitTestClip(double x, double y)
    {
        if (TrackIndexForY(y) is not { } trackIndex) return null;
        var frame = x / PixelsPerFrame;
        foreach (var clip in Timeline.Tracks[trackIndex].Clips)
        {
            if (frame >= clip.StartFrame && frame < clip.EndFrame) return (trackIndex, clip);
        }
        return null;
    }
}

/// <summary>Zoom rules: fit-all minimum, cursor/playhead anchoring, log slider mapping.</summary>
public static class TimelineZoom
{
    public static double MinZoomScale(double availableWidth, int totalFrames)
    {
        if (totalFrames <= 0) return EditorDefaults.PixelsPerFrame;
        var fitAll = availableWidth / (totalFrames * Zoom.FitAllBuffer);
        return Math.Min(Zoom.Max, Math.Max(Zoom.Floor, fitAll));
    }

    /// <summary>Cursor-anchored zoom: keeps the frame under the cursor stationary.</summary>
    public static (double Scale, double ScrollX) ApplyZoom(
        double currentScale, double factor, double minScale,
        double anchorDocX, double anchorViewportX)
    {
        var frameUnderCursor = Math.Max(0.0, anchorDocX / currentScale);
        var newScale = Math.Max(minScale, Math.Min(Zoom.Max, currentScale * factor));
        var scrollX = Math.Max(0, frameUnderCursor * newScale - anchorViewportX);
        return (newScale, scrollX);
    }

    /// <summary>Playhead-anchored zoom for toolbar-driven changes.</summary>
    public static double PlayheadAnchoredScrollX(
        double previousScale, double newScale, int playheadFrame,
        double scrollX, double visibleWidth)
    {
        var playheadPrevX = playheadFrame * previousScale;
        var anchorViewportX = playheadPrevX >= scrollX && playheadPrevX <= scrollX + visibleWidth
            ? playheadPrevX - scrollX
            : visibleWidth * 0.5;
        return Math.Max(0, playheadFrame * newScale - anchorViewportX);
    }
}

public sealed record SnapResult(int Frame, int ProbeOffset, double X);

public sealed class SnapState
{
    public int? CurrentlySnappedTo;
    public int CurrentProbeOffset;
}

/// <summary>
/// Snapping with sticky hold and playhead priority. Probes are candidate frames
/// (selected clip starts/ends) expressed as offsets from the dragged position.
/// </summary>
public static class TimelineSnap
{
    public static SnapResult? Find(
        int position,
        IReadOnlyList<int> probeOffsets,
        IReadOnlyList<(int Frame, bool IsPlayhead)> targets,
        double pixelsPerFrame,
        SnapState state)
    {
        if (targets.Count == 0 || probeOffsets.Count == 0 || pixelsPerFrame <= 0) return null;
        var baseFrameThreshold = Snap.ThresholdPixels / pixelsPerFrame;

        // Sticky: stay snapped while within the hold radius of the current target.
        if (state.CurrentlySnappedTo is { } snapped)
        {
            var holdThreshold = baseFrameThreshold * Snap.StickyMultiplier;
            var probePosition = position + state.CurrentProbeOffset;
            if (Math.Abs((double)(probePosition - snapped)) <= holdThreshold
                && targets.Any(t => t.Frame == snapped))
            {
                return new SnapResult(snapped, state.CurrentProbeOffset, snapped * pixelsPerFrame);
            }
        }

        SnapResult? best = null;
        var bestDistance = double.MaxValue;
        foreach (var probe in probeOffsets)
        {
            var probePosition = position + probe;
            foreach (var (frame, isPlayhead) in targets)
            {
                var threshold = baseFrameThreshold * (isPlayhead ? Snap.PlayheadMultiplier : 1.0);
                var distance = Math.Abs((double)(probePosition - frame));
                if (distance <= threshold && distance < bestDistance)
                {
                    bestDistance = distance;
                    best = new SnapResult(frame, probe, frame * pixelsPerFrame);
                }
            }
        }

        state.CurrentlySnappedTo = best?.Frame;
        state.CurrentProbeOffset = best?.ProbeOffset ?? 0;
        return best;
    }
}

/// <summary>Ruler tick math: major ticks ~80 px apart on nice second intervals.</summary>
public static class TimelineRulerMath
{
    private static readonly double[] NiceSeconds = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600];

    public static int MajorIntervalFrames(int fps, double pixelsPerFrame)
    {
        var targetFrames = 80.0 / Math.Max(Zoom.Floor, pixelsPerFrame);
        foreach (var seconds in NiceSeconds)
        {
            var frames = seconds * fps;
            if (frames >= targetFrames) return (int)frames;
        }
        return (int)(NiceSeconds[^1] * fps);
    }

    public static int MinorSubdivisions(int majorFrames, double pixelsPerFrame)
    {
        foreach (var candidate in new[] { 10, 5, 4, 2 })
        {
            if (majorFrames * pixelsPerFrame / candidate >= 12) return candidate;
        }
        return 1;
    }

    public static string FormatTimecode(int frame, int fps)
    {
        fps = Math.Max(1, fps);
        var totalSeconds = frame / fps;
        return $"{totalSeconds / 3600:00}:{totalSeconds % 3600 / 60:00}:{totalSeconds % 60:00}:{frame % fps:00}";
    }
}
