using PalmierPro.App.Editing;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.Editing;

public class TimelineZoomTests
{
    [Fact]
    public void PositiveDeltaZoomsIn()
    {
        TimelineZoom.Apply(4.0, wheelDelta: 10).ShouldBeGreaterThan(4.0);
    }

    [Fact]
    public void NegativeDeltaZoomsOut()
    {
        TimelineZoom.Apply(4.0, wheelDelta: -10).ShouldBeLessThan(4.0);
    }

    [Fact]
    public void ZeroDeltaIsANoOp()
    {
        TimelineZoom.Apply(4.0, wheelDelta: 0).ShouldBe(4.0);
    }

    [Fact]
    public void ClampsToMax()
    {
        TimelineZoom.Apply(TimelineInputConstants.Zoom.Max, wheelDelta: 1000).ShouldBe(TimelineInputConstants.Zoom.Max);
    }

    [Fact]
    public void ClampsToMin()
    {
        TimelineZoom.Apply(TimelineInputConstants.Zoom.Min, wheelDelta: -1000).ShouldBe(TimelineInputConstants.Zoom.Min);
    }

    [Fact]
    public void ScrollXForAnchorKeepsFrameUnderCursor()
    {
        // Frame 100 at 8 px/frame should sit at document x=800; if the viewport wants that frame
        // at screen x=50, the scroll offset is 750.
        TimelineZoom.ScrollXForAnchor(anchorFrame: 100, newPixelsPerFrame: 8, anchorViewportX: 50).ShouldBe(750);
    }

    [Fact]
    public void ScrollXForAnchorNeverGoesNegative()
    {
        TimelineZoom.ScrollXForAnchor(anchorFrame: 0, newPixelsPerFrame: 8, anchorViewportX: 500).ShouldBe(0);
    }

    [Fact]
    public void ScrollXForAnchorAccountsForHeaderWidth()
    {
        TimelineZoom.ScrollXForAnchor(anchorFrame: 10, newPixelsPerFrame: 4, anchorViewportX: 140, headerWidth: 100).ShouldBe(0);
    }

    private static MediaAsset Asset(ClipType type) => new("C:\\media\\a.mp4", type, "a");

    [Fact]
    public void PreferredTrackTypeIsVideoForAllVideo()
    {
        TimelineZoom.PreferredTrackType([Asset(ClipType.Video), Asset(ClipType.Video)]).ShouldBe(ClipType.Video);
    }

    [Fact]
    public void PreferredTrackTypeIsAudioForAllAudio()
    {
        TimelineZoom.PreferredTrackType([Asset(ClipType.Audio), Asset(ClipType.Audio)]).ShouldBe(ClipType.Audio);
    }

    [Fact]
    public void PreferredTrackTypeIsVideoForMixedSelection()
    {
        TimelineZoom.PreferredTrackType([Asset(ClipType.Audio), Asset(ClipType.Video)]).ShouldBe(ClipType.Video);
    }

    [Fact]
    public void PreferredTrackTypeIsVideoForEmptySelection()
    {
        TimelineZoom.PreferredTrackType([]).ShouldBe(ClipType.Video);
    }
}
