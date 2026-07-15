using PalmierPro.App.Editing;
using PalmierPro.App.Tests.ViewModels.Editor;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.Editing;

public class TimelineHitTestingTests
{
    [Fact]
    public void EdgeAtLeftHandleReturnsLeft() => TimelineHitTesting.EdgeAt(2, 200, handleWidth: 6).ShouldBe(TrimEdge.Left);

    [Fact]
    public void EdgeAtRightHandleReturnsRight() => TimelineHitTesting.EdgeAt(198, 200, handleWidth: 6).ShouldBe(TrimEdge.Right);

    [Fact]
    public void EdgeAtMiddleReturnsNull() => TimelineHitTesting.EdgeAt(100, 200, handleWidth: 6).ShouldBeNull();

    [Fact]
    public void EdgeAtZeroWidthClipReturnsNull() => TimelineHitTesting.EdgeAt(0, 0, handleWidth: 6).ShouldBeNull();

    private static TimelineGeometry Geometry(double pxPerFrame = 4, double header = 100) =>
        new(pxPerFrame, [50, 50], header);

    [Fact]
    public void HitTestClipFindsClipUnderPoint()
    {
        var clip = EditorFixtures.Clip(id: "a", start: 10, duration: 20);
        var timeline = EditorFixtures.Timeline(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        var geo = Geometry();
        var rect = geo.ClipRect(clip, 0);

        var hit = TimelineHitTesting.HitTestClip(timeline, geo, rect.X + 1, rect.Y + 1);
        hit.ShouldNotBeNull();
        hit!.Value.TrackIndex.ShouldBe(0);
        hit.Value.ClipIndex.ShouldBe(0);
    }

    [Fact]
    public void HitTestClipMissReturnsNull()
    {
        var clip = EditorFixtures.Clip(id: "a", start: 10, duration: 20);
        var timeline = EditorFixtures.Timeline(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        var geo = Geometry();

        TimelineHitTesting.HitTestClip(timeline, geo, 0, 0).ShouldBeNull();
    }

    [Fact]
    public void HitTestClipOutOfRangeTrackReturnsNull()
    {
        var timeline = EditorFixtures.Timeline(tracks: []);
        var geo = Geometry();
        TimelineHitTesting.HitTestClip(timeline, geo, 500, 500).ShouldBeNull();
    }

    [Fact]
    public void HitTestGapBetweenTwoClipsReturnsRange()
    {
        var track = EditorFixtures.VideoTrack(clips: [
            EditorFixtures.Clip(id: "a", start: 0, duration: 50),
            EditorFixtures.Clip(id: "b", start: 100, duration: 50),
        ]);
        var timeline = EditorFixtures.Timeline(tracks: [track]);
        var geo = Geometry();
        var y = geo.TrackY(0) + 1;
        var x = geo.XForFrame(75);

        var gap = TimelineHitTesting.HitTestGap(timeline, geo, 0, x, y);
        gap.ShouldNotBeNull();
        gap!.Value.TrackIndex.ShouldBe(0);
        gap.Value.Range.Start.ShouldBe(50);
        gap.Value.Range.End.ShouldBe(100);
    }

    [Fact]
    public void HitTestGapInsideClipReturnsNull()
    {
        var track = EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "a", start: 0, duration: 50)]);
        var timeline = EditorFixtures.Timeline(tracks: [track]);
        var geo = Geometry();
        var y = geo.TrackY(0) + 1;

        TimelineHitTesting.HitTestGap(timeline, geo, 0, geo.XForFrame(10), y).ShouldBeNull();
    }

    [Fact]
    public void HitTestGapPastLastClipReturnsNull()
    {
        var track = EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "a", start: 0, duration: 50)]);
        var timeline = EditorFixtures.Timeline(tracks: [track]);
        var geo = Geometry();
        var y = geo.TrackY(0) + 1;

        TimelineHitTesting.HitTestGap(timeline, geo, 0, geo.XForFrame(200), y).ShouldBeNull();
    }

    [Fact]
    public void HitTestGapOutsideTrackVerticalBoundsReturnsNull()
    {
        var track = EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "a", start: 0, duration: 50)]);
        var timeline = EditorFixtures.Timeline(tracks: [track]);
        var geo = Geometry();

        TimelineHitTesting.HitTestGap(timeline, geo, 0, geo.XForFrame(75), 0).ShouldBeNull();
    }
}
