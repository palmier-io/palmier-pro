using PalmierPro.Services.Engine;
using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests.Engine;

/// Pins <see cref="VideoEngine.AssetPreviewSeekSeconds"/>'s formula — the fix for the
/// source-preview scrub bug where <c>PerformAssetPreviewSeek</c> divided by the ASSET's own
/// decoded fps (<c>MediaSource.Info.Fps</c>) instead of the TIMELINE's fps that `frame` is always
/// expressed in (see <c>PreviewViewModel.SourceDurationFrames</c>/<c>SourceFrame</c>). No native
/// engine/decodable file needed — pure arithmetic, same reasoning as SeekCoordinatorTests testing
/// <see cref="SeekCoordinator.InteractiveTolerance"/> directly.
public sealed class VideoEngineAssetPreviewSeekTests
{
    // The finding's own repro: a 24fps clip on a 30fps timeline. SourceDurationFrames for a 10s
    // clip is SecondsToFrame(10, 30) = 300 timeline-frames. Dividing by the asset's own 24fps (the
    // bug) lands at 300/24 = 12.5s — 2.5s past the clip's actual 10s end. Dividing by the timeline's
    // 30fps (the fix) lands exactly at the clip's real duration.
    [Fact]
    public void UsesTimelineFps_NotAssetFps_ForA24fpsClipOnA30fpsTimeline()
    {
        const int timelineFps = 30;
        const int sourceDurationFrames = 300; // SwiftMath.SecondsToFrame(10.0, timelineFps)

        double seconds = VideoEngine.AssetPreviewSeekSeconds(sourceDurationFrames, timelineFps);

        seconds.ShouldBe(10.0, tolerance: 1e-9);
        seconds.ShouldNotBe(12.5); // what the pre-fix `frame / assetFps` (24) would have produced
    }

    // The finding's second repro direction: a 60fps clip on a 30fps timeline can never reach its
    // end under the bug (frame / 60 always undershoots the 30fps-timeline-relative duration).
    [Fact]
    public void UsesTimelineFps_NotAssetFps_ForA60fpsClipOnA30fpsTimeline()
    {
        const int timelineFps = 30;
        const int sourceDurationFrames = 150; // SwiftMath.SecondsToFrame(5.0, timelineFps)

        double seconds = VideoEngine.AssetPreviewSeekSeconds(sourceDurationFrames, timelineFps);

        seconds.ShouldBe(5.0, tolerance: 1e-9); // the clip's actual 5s duration, fully reachable
        seconds.ShouldNotBe(2.5); // what the pre-fix `frame / assetFps` (60) would have produced
    }

    [Fact]
    public void MatchingFps_IsTheDegenerateCase()
    {
        VideoEngine.AssetPreviewSeekSeconds(90, 30).ShouldBe(3.0, tolerance: 1e-9);
    }

    [Fact]
    public void FrameZero_IsAlwaysZeroSeconds_RegardlessOfFps()
    {
        VideoEngine.AssetPreviewSeekSeconds(0, 24).ShouldBe(0.0, tolerance: 1e-9);
        VideoEngine.AssetPreviewSeekSeconds(0, 60).ShouldBe(0.0, tolerance: 1e-9);
    }

    // Mirrors PerformAssetPreviewSeek's pre-fix `media.Info.Fps > 0 ? media.Info.Fps : 30` guard —
    // a zero/negative fps (shouldn't happen for an open timeline, but Timeline.Fps is a plain
    // settable int) falls back to 30 rather than dividing by zero or negating the seek direction.
    [Theory]
    [InlineData(0)]
    [InlineData(-30)]
    public void NonPositiveTimelineFps_FallsBackTo30(int timelineFps)
    {
        VideoEngine.AssetPreviewSeekSeconds(60, timelineFps).ShouldBe(2.0, tolerance: 1e-9);
    }
}
