using PalmierPro.Core.Models;
using PalmierPro.Core.Playback;
using Xunit;

namespace PalmierPro.Core.Tests;

public class TimelineGeometryTests
{
    private static Timeline TwoTracks()
    {
        return new Timeline
        {
            Fps = 30,
            Tracks =
            [
                new Track
                {
                    Type = ClipType.Video,
                    DisplayHeight = 50,
                    Clips = [new Clip { MediaRef = "a", StartFrame = 30, DurationFrames = 60 }],
                },
                new Track { Type = ClipType.Audio, DisplayHeight = 40, Clips = [] },
            ],
        };
    }

    [Fact]
    public void VerticalLayoutStacksRulerDropZoneAndTracks()
    {
        var geometry = new TimelineGeometry(TwoTracks(), 4.0);
        Assert.Equal(84, geometry.TrackTop(0));            // 24 + 60
        Assert.Equal(134, geometry.TrackTop(1));           // + 50
        Assert.Equal(234, geometry.ContentHeight);         // + 40 + 60
    }

    [Fact]
    public void ClipRectUsesGutterAndZoom()
    {
        var geometry = new TimelineGeometry(TwoTracks(), 4.0);
        var clip = TwoTracks().Tracks[0].Clips[0];
        var rect = geometry.ClipRect(0, clip);
        Assert.Equal(120, rect.X);      // 30 * 4
        Assert.Equal(240, rect.Width);  // 60 * 4
        Assert.Equal(86, rect.Y);       // trackTop + 2
        Assert.Equal(46, rect.Height);  // 50 - 4
    }

    [Fact]
    public void HitTestFindsClipAndGaps()
    {
        var timeline = TwoTracks();
        var geometry = new TimelineGeometry(timeline, 4.0);
        var hit = geometry.HitTestClip(130, 100);
        Assert.NotNull(hit);
        Assert.Equal("a", hit!.Value.Clip.MediaRef);
        Assert.Null(geometry.HitTestClip(20, 100));   // before clip
        Assert.Null(geometry.HitTestClip(130, 10));   // in ruler
    }

    [Fact]
    public void CursorAnchoredZoomKeepsFrameUnderCursor()
    {
        var (scale, scrollX) = TimelineZoom.ApplyZoom(
            currentScale: 4.0, factor: 2.0, minScale: 0.05,
            anchorDocX: 400, anchorViewportX: 100);
        Assert.Equal(8.0, scale);
        // Frame 100 was under cursor; new doc x = 800, viewport anchor 100 ⇒ scroll 700.
        Assert.Equal(700, scrollX);
    }

    [Fact]
    public void ZoomClampsToMax()
    {
        var (scale, _) = TimelineZoom.ApplyZoom(30, 4.0, 0.05, 0, 0);
        Assert.Equal(40.0, scale);
    }

    [Fact]
    public void FitAllMinZoomUsesBuffer()
    {
        // 1200 px / (300 frames * 3) = 1.333…
        Assert.Equal(1200.0 / 900.0, TimelineZoom.MinZoomScale(1200, 300), 9);
    }
}

public class TimelineSnapTests
{
    [Fact]
    public void SnapsToNearestTargetWithinThreshold()
    {
        var state = new SnapState();
        var result = TimelineSnap.Find(
            position: 99, probeOffsets: [0], targets: [(100, false)],
            pixelsPerFrame: 4.0, state: state);
        Assert.NotNull(result);
        Assert.Equal(100, result!.Frame);
    }

    [Fact]
    public void OutOfThresholdDoesNotSnap()
    {
        var state = new SnapState();
        // Threshold = 8px / 4ppf = 2 frames; distance 3.
        Assert.Null(TimelineSnap.Find(97, [0], [(100, false)], 4.0, state));
    }

    [Fact]
    public void StickyHoldKeepsSnapBeyondBaseThreshold()
    {
        var state = new SnapState();
        Assert.NotNull(TimelineSnap.Find(99, [0], [(100, false)], 4.0, state));
        // Distance 3 exceeds base threshold 2 but is within hold (2 * 1.5 = 3).
        var held = TimelineSnap.Find(97, [0], [(100, false)], 4.0, state);
        Assert.NotNull(held);
        Assert.Equal(100, held!.Frame);
    }

    [Fact]
    public void PlayheadHasWiderThreshold()
    {
        var state = new SnapState();
        // Distance 3 > base 2 but ≤ playhead 3.
        var result = TimelineSnap.Find(97, [0], [(100, true)], 4.0, state);
        Assert.NotNull(result);
    }

    [Fact]
    public void ProbeOffsetsSnapClipEnds()
    {
        var state = new SnapState();
        // Dragged clip start=48, end offset +30; target at 80 should catch the end probe.
        var result = TimelineSnap.Find(49, [0, 30], [(80, false)], 4.0, state);
        Assert.NotNull(result);
        Assert.Equal(80, result!.Frame);
        Assert.Equal(30, result.ProbeOffset);
    }
}

public class TimelineRulerMathTests
{
    [Theory]
    [InlineData(30, 4.0, 30)]      // 80/4 = 20 frames → 1 s = 30 frames
    [InlineData(30, 0.5, 300)]     // 160 frames → 10 s
    [InlineData(30, 0.05, 1800)]   // 1600 frames → 60 s
    public void MajorIntervalPicksNiceSeconds(int fps, double ppf, int expectedFrames)
    {
        Assert.Equal(expectedFrames, TimelineRulerMath.MajorIntervalFrames(fps, ppf));
    }

    [Fact]
    public void TimecodeFormatsHoursMinutesSecondsFrames()
    {
        Assert.Equal("00:00:01:05", TimelineRulerMath.FormatTimecode(35, 30));
        Assert.Equal("01:00:00:00", TimelineRulerMath.FormatTimecode(108000, 30));
    }
}
