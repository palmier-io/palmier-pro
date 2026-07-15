using PalmierPro.Core.Models;

namespace PalmierPro.App.Editing;

/// Where a track-header drop lands: on an existing track, or inserting a new one before `Index`.
/// Ported from Timeline/TimelineGeometry.swift's `TrackDropTarget` enum.
public abstract record TrackDropTarget
{
    public sealed record ExistingTrack(int Index) : TrackDropTarget;

    public sealed record NewTrackAt(int Index) : TrackDropTarget;
}

/// Axis-aligned rect in timeline-canvas pixels. A local, dependency-free stand-in for AppKit's
/// `NSRect` (same field shape — origin + size, Y-down) so this file stays free of any WinUI/WinRT
/// type and is safe to unit test under plain `dotnet test`.
public readonly record struct EditorRect(double X, double Y, double Width, double Height);

/// Pure layout math for the timeline, ported near-verbatim from Timeline/TimelineGeometry.swift.
/// Used by both the timeline drawing surface and hit-testing during drag — neither exists yet on
/// Windows (Stage D/E), but the math is settled now so both build against it unchanged.
public sealed class TimelineGeometry
{
    /// Layout constants mirrored from Utilities/Constants.swift's `Layout` enum — the subset this
    /// class needs. Kept local rather than added to `PalmierPro.Core` (whose `LayoutDefaults`
    /// deliberately excludes UI-layout constants; see that file's doc comment).
    public static class Layout
    {
        public const double RulerHeight = 24;
        public const double DropZoneHeight = 60;
        public const double TrackHeight = 50;
        public const double InsertThreshold = 10;
        /// Mirrors Mac's `Layout.trackHeaderWidth` — used by the Win2D timeline view (Stage C) for
        /// the fixed-left track-header column.
        public const double HeaderWidth = 100;
    }

    public double PixelsPerFrame { get; }
    public double HeaderWidth { get; }
    public double RulerHeight { get; }
    public int TrackCount { get; }
    public IReadOnlyList<double> TrackHeights { get; }

    /// Precomputed cumulative Y offsets for each track (avoids O(n) per lookup).
    private readonly List<double> _cumulativeY;

    public TimelineGeometry(double pixelsPerFrame, IReadOnlyList<double> trackHeights, double headerWidth = 0)
    {
        PixelsPerFrame = pixelsPerFrame;
        HeaderWidth = headerWidth;
        RulerHeight = Layout.RulerHeight;
        TrackCount = trackHeights.Count;
        TrackHeights = trackHeights;

        _cumulativeY = new List<double>(trackHeights.Count);
        var y = RulerHeight + Layout.DropZoneHeight;
        foreach (var h in trackHeights)
        {
            _cumulativeY.Add(y);
            y += h;
        }
    }

    public double TrackHeight(int index) =>
        index >= 0 && index < TrackHeights.Count ? TrackHeights[index] : Layout.TrackHeight;

    public double TrackY(int index) =>
        index >= 0 && index < _cumulativeY.Count ? _cumulativeY[index] : RulerHeight;

    public EditorRect ClipRect(Clip clip, int trackIndex) =>
        ClipRect(clip, TrackY(trackIndex), TrackHeight(trackIndex));

    /// Clip rect at an arbitrary Y position (used for ghost clips at insertion lines).
    public EditorRect ClipRect(Clip clip, double y, double height) => new(
        HeaderWidth + clip.StartFrame * PixelsPerFrame,
        y + 2,
        clip.DurationFrames * PixelsPerFrame,
        height - 4);

    public int FrameAt(double x) => Math.Max(0, (int)((x - HeaderWidth) / PixelsPerFrame));

    public int TrackAt(double y)
    {
        for (var i = 0; i < _cumulativeY.Count; i++)
        {
            if (y < _cumulativeY[i] + TrackHeights[i])
            {
                return i;
            }
        }
        return Math.Max(0, TrackCount - 1);
    }

    public TrackDropTarget DropTargetAt(double y)
    {
        if (TrackCount == 0)
        {
            return new TrackDropTarget.NewTrackAt(0);
        }

        // Top drop zone.
        if (y < _cumulativeY[0])
        {
            return new TrackDropTarget.NewTrackAt(0);
        }

        // Check between-track boundaries.
        const double threshold = Layout.InsertThreshold;
        for (var i = 0; i < TrackCount - 1; i++)
        {
            var bottomOfTrack = _cumulativeY[i] + TrackHeights[i];
            var topOfNext = _cumulativeY[i + 1];
            // The boundary region: threshold above the gap to threshold below.
            if (y >= bottomOfTrack - threshold && y <= topOfNext + threshold)
            {
                return new TrackDropTarget.NewTrackAt(i + 1);
            }
        }

        // Bottom drop zone: past the last track.
        var lastTrackBottom = _cumulativeY[TrackCount - 1] + TrackHeights[TrackCount - 1];
        if (y >= lastTrackBottom)
        {
            return new TrackDropTarget.NewTrackAt(TrackCount);
        }

        // On an existing track.
        for (var i = 0; i < _cumulativeY.Count; i++)
        {
            if (y < _cumulativeY[i] + TrackHeights[i])
            {
                return new TrackDropTarget.ExistingTrack(i);
            }
        }
        return new TrackDropTarget.ExistingTrack(Math.Max(0, TrackCount - 1));
    }

    public double? InsertionLineY(TrackDropTarget target)
    {
        if (target is not TrackDropTarget.NewTrackAt(var index))
        {
            return null;
        }
        if (TrackCount == 0)
        {
            return RulerHeight + Layout.DropZoneHeight;
        }
        if (index == 0)
        {
            return _cumulativeY[0];
        }
        if (index >= TrackCount)
        {
            return _cumulativeY[TrackCount - 1] + TrackHeights[TrackCount - 1];
        }
        return _cumulativeY[index];
    }

    /// Y position where a ghost clip should render for a new-track drop.
    public double? GhostY(TrackDropTarget target, double height = Layout.TrackHeight)
    {
        if (target is not TrackDropTarget.NewTrackAt(var index) || InsertionLineY(target) is not { } lineY)
        {
            return null;
        }
        return index < TrackCount ? lineY - height : lineY;
    }

    public double XForFrame(int frame) => HeaderWidth + frame * PixelsPerFrame;
}
