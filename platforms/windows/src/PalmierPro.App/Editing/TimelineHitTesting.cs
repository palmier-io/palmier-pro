using PalmierPro.Core.Models;
using PalmierPro.Core.Timeline;

namespace PalmierPro.App.Editing;

public enum TrimEdge
{
    Left,
    Right,
}

/// Pure pointer hit-testing math, ported from the relevant slices of
/// Timeline/TimelineInputController.swift (`trimEdge(localX:clipWidth:)`, `hitTestClip`,
/// `hitTestGap`). Split out of the input controller so it's unit-testable under plain
/// `dotnet test`; TimelineCanvasControl drives it with live pointer coordinates.
public static class TimelineHitTesting
{
    /// Which trim handle (if any) a pointer at `localX` within a clip of `clipWidth` is over.
    public static TrimEdge? EdgeAt(double localX, double clipWidth, double handleWidth = TimelineInputConstants.Trim.HandleWidth)
    {
        if (clipWidth <= 0)
        {
            return null;
        }
        if (localX <= handleWidth)
        {
            return TrimEdge.Left;
        }
        if (localX >= clipWidth - handleWidth)
        {
            return TrimEdge.Right;
        }
        return null;
    }

    public static ClipLocation? HitTestClip(Timeline timeline, TimelineGeometry geometry, double x, double y)
    {
        var trackIndex = geometry.TrackAt(y);
        if (trackIndex < 0 || trackIndex >= timeline.Tracks.Count)
        {
            return null;
        }
        var clips = timeline.Tracks[trackIndex].Clips;
        for (var i = 0; i < clips.Count; i++)
        {
            var rect = geometry.ClipRect(clips[i], trackIndex);
            if (x >= rect.X && x < rect.X + rect.Width && y >= rect.Y && y < rect.Y + rect.Height)
            {
                return new ClipLocation(trackIndex, i);
            }
        }
        return null;
    }

    /// Empty track space bounded on the right by a clip: `[previousClipEnd, nextClipStart)`.
    public static GapSelection? HitTestGap(Timeline timeline, TimelineGeometry geometry, int trackIndex, double x, double y)
    {
        if (trackIndex < 0 || trackIndex >= timeline.Tracks.Count)
        {
            return null;
        }
        var top = geometry.TrackY(trackIndex);
        var bottom = top + geometry.TrackHeight(trackIndex);
        if (y < top || y >= bottom)
        {
            return null;
        }

        var frame = geometry.FrameAt(x);
        var clips = timeline.Tracks[trackIndex].Clips;
        if (clips.Any(c => frame >= c.StartFrame && frame < c.EndFrame))
        {
            return null;
        }
        var nextStart = clips.Select(c => c.StartFrame).Where(s => s > frame).DefaultIfEmpty(-1).Min();
        if (nextStart < 0)
        {
            return null;
        }
        var prevEnd = clips.Select(c => c.EndFrame).Where(e => e <= frame).DefaultIfEmpty(0).Max();
        return new GapSelection(trackIndex, new FrameRange(prevEnd, nextStart));
    }
}
