using PalmierPro.App.Editing;
using PalmierPro.App.Tests.ViewModels.Editor;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.Editing;

/// Mirrors Tests/PalmierProTests/Timeline/TimelineGeometryTests.swift.
public class TimelineGeometryTests
{
    // Three tracks of 50 each. baseY = rulerHeight (24) + dropZoneHeight (60) = 84.
    // cumulativeY = [84, 134, 184]; track bottoms = [134, 184, 234]. All assertions derive from this.
    private static TimelineGeometry Geometry(double pxPerFrame = 4, double header = 0) =>
        new(pxPerFrame, [50, 50, 50], header);

    [Fact]
    public void FrameAtAndXForFrameRoundtrip()
    {
        var g = Geometry();
        g.XForFrame(100).ShouldBe(400); // 100 * 4
        g.FrameAt(400).ShouldBe(100);
    }

    [Fact]
    public void XForFrameIncludesHeaderWidth()
    {
        var g = Geometry(header: 100);
        g.XForFrame(50).ShouldBe(300); // 100 + 50*4
        g.FrameAt(300).ShouldBe(50);
    }

    [Fact]
    public void FrameAtBeforeHeaderClampsToZero()
    {
        var g = Geometry(header: 100);
        g.FrameAt(0).ShouldBe(0);
    }

    [Fact]
    public void TrackYReturnsCumulativeOffsets()
    {
        var g = Geometry();
        g.TrackY(0).ShouldBe(84);
        g.TrackY(1).ShouldBe(134);
        g.TrackY(2).ShouldBe(184);
    }

    [Fact]
    public void TrackYOutOfBoundsReturnsRulerHeight()
    {
        var g = Geometry();
        g.TrackY(99).ShouldBe(TimelineGeometry.Layout.RulerHeight);
    }

    [Fact]
    public void ClipRectInsetsTwoPxTopAndBottom()
    {
        var g = Geometry();
        var clip = EditorFixtures.Clip(start: 100, duration: 50);
        var rect = g.ClipRect(clip, 0);
        // x = 100*4 = 400. y = 84 + 2 = 86. w = 50*4 = 200. h = 50 - 4 = 46.
        rect.X.ShouldBe(400);
        rect.Y.ShouldBe(86);
        rect.Width.ShouldBe(200);
        rect.Height.ShouldBe(46);
    }

    [Fact]
    public void TrackAtReturnsCorrectTrackIndex()
    {
        var g = Geometry();
        g.TrackAt(100).ShouldBe(0); // 84 <= 100 < 134
        g.TrackAt(140).ShouldBe(1); // 134 <= 140 < 184
        g.TrackAt(200).ShouldBe(2); // 184 <= 200 < 234
    }

    [Fact]
    public void TrackAtBelowLastTrackClampsToLast()
    {
        var g = Geometry();
        g.TrackAt(1000).ShouldBe(2);
    }

    [Fact]
    public void DropTargetAboveFirstTrackIsNewTrackAtZero()
    {
        var g = Geometry();
        // y < cumY[0] (84).
        g.DropTargetAt(50).ShouldBe(new TrackDropTarget.NewTrackAt(0));
    }

    [Fact]
    public void DropTargetBetweenTracksWithinThresholdIsNewTrack()
    {
        var g = Geometry();
        // Boundary between track 0 and 1 is at y=134. Threshold is 10. Range [124, 144].
        g.DropTargetAt(130).ShouldBe(new TrackDropTarget.NewTrackAt(1));
        g.DropTargetAt(134).ShouldBe(new TrackDropTarget.NewTrackAt(1));
    }

    [Fact]
    public void DropTargetOnExistingTrackBodyIsExistingTrack()
    {
        var g = Geometry();
        // Track 0 body is [84, 134). Outside the boundary zones -- y=100 should land in body.
        g.DropTargetAt(100).ShouldBe(new TrackDropTarget.ExistingTrack(0));
        g.DropTargetAt(200).ShouldBe(new TrackDropTarget.ExistingTrack(2));
    }

    [Fact]
    public void DropTargetBelowLastTrackIsNewTrackAtCount()
    {
        var g = Geometry();
        // Last track bottom is 234.
        g.DropTargetAt(250).ShouldBe(new TrackDropTarget.NewTrackAt(3));
    }

    [Fact]
    public void DropTargetWithEmptyTimelineIsNewTrackAtZero()
    {
        var g = new TimelineGeometry(4, []);
        g.DropTargetAt(100).ShouldBe(new TrackDropTarget.NewTrackAt(0));
    }

    [Fact]
    public void InsertionLineYIsNilForExistingTrack()
    {
        var g = Geometry();
        g.InsertionLineY(new TrackDropTarget.ExistingTrack(1)).ShouldBeNull();
    }

    [Fact]
    public void InsertionLineYAtTopReturnsFirstCumulative()
    {
        var g = Geometry();
        g.InsertionLineY(new TrackDropTarget.NewTrackAt(0)).ShouldBe(84);
    }

    [Fact]
    public void InsertionLineYBetweenTracksReturnsBoundary()
    {
        var g = Geometry();
        g.InsertionLineY(new TrackDropTarget.NewTrackAt(1)).ShouldBe(134);
        g.InsertionLineY(new TrackDropTarget.NewTrackAt(2)).ShouldBe(184);
    }

    [Fact]
    public void InsertionLineYAtBottomReturnsLastBottom()
    {
        var g = Geometry();
        // index == trackCount -> last cumulativeY + last height = 184 + 50 = 234.
        g.InsertionLineY(new TrackDropTarget.NewTrackAt(3)).ShouldBe(234);
    }
}
