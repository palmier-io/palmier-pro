using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

/// Mirrors Tests/PalmierProTests/Timeline/ClipMathTests.swift.
public class ClipMathTests
{
    // MARK: endFrame / source-frame math

    [Fact]
    public void EndFrameIsStartPlusDuration()
    {
        var clip = Fixtures.Clip(start: 100, duration: 50);
        clip.EndFrame.ShouldBe(150);
    }

    [Fact]
    public void SourceFramesConsumedScalesBySpeed()
    {
        // duration=100 timeline frames x speed=2.0 -> 200 source frames consumed.
        var clip = Fixtures.Clip(start: 0, duration: 100, speed: 2.0);
        clip.SourceFramesConsumed.ShouldBe(200);
    }

    [Fact]
    public void SourceFramesConsumedRoundsForFractionalSpeed()
    {
        // 33 * 0.75 = 24.75 -> rounds to 25.
        var clip = Fixtures.Clip(start: 0, duration: 33, speed: 0.75);
        clip.SourceFramesConsumed.ShouldBe(25);
    }

    [Fact]
    public void SourceDurationIncludesBothTrims()
    {
        // consumed (100) + trimStart (10) + trimEnd (5) = 115.
        var clip = Fixtures.Clip(start: 0, duration: 100, trimStart: 10, trimEnd: 5);
        clip.SourceDurationFrames.ShouldBe(115);
    }

    // MARK: Contains(timelineFrame:)

    [Fact]
    public void ContainsIsHalfOpen()
    {
        // Half-open interval [startFrame, endFrame). endFrame belongs to whatever comes next.
        var clip = Fixtures.Clip(start: 50, duration: 30); // endFrame = 80
        clip.Contains(50).ShouldBeTrue();
        clip.Contains(79).ShouldBeTrue();
        clip.Contains(80).ShouldBeFalse();
        clip.Contains(49).ShouldBeFalse();
    }

    // MARK: TimelineFrame(sourceSeconds:fps:)

    [Fact]
    public void TimelineFrameMapsSourceSecondsThroughTrim()
    {
        // start=100, trimStart=30 source frames, speed=1, fps=30.
        // sourceSeconds=2.0 -> 60 source frames -> offsetFromTrim=30 -> timeline = 100+30 = 130.
        var clip = Fixtures.Clip(start: 100, duration: 60, trimStart: 30);
        clip.TimelineFrame(2.0, 30).ShouldBe(130);
    }

    [Fact]
    public void TimelineFrameDividesBySpeed()
    {
        // start=0, speed=2.0, fps=30. sourceSeconds=2.0 -> 60 source frames -> 60/2 = 30 timeline frames.
        var clip = Fixtures.Clip(start: 0, duration: 100, speed: 2.0);
        clip.TimelineFrame(2.0, 30).ShouldBe(30);
    }

    [Fact]
    public void TimelineFrameBeforeTrimReturnsNull()
    {
        // sourceSeconds=0.5 -> 15 source frames; trimStart=30 -> offsetFromTrim < 0 -> null.
        var clip = Fixtures.Clip(start: 100, duration: 60, trimStart: 30);
        clip.TimelineFrame(0.5, 30).ShouldBeNull();
    }

    [Fact]
    public void TimelineFrameAtOrPastEndFrameReturnsNull()
    {
        // Note: the guard here is `< endFrame` (exclusive), unlike Contains() which uses `<=`.
        var clip = Fixtures.Clip(start: 0, duration: 30);
        clip.TimelineFrame(1.0, 30).ShouldBeNull();
        clip.TimelineFrame(2.0, 30).ShouldBeNull();
    }

    // MARK: fadeMultiplier

    [Fact]
    public void FadeMultiplierIsOneEverywhereWithNoFades()
    {
        var clip = Fixtures.Clip(start: 0, duration: 100);
        clip.FadeMultiplier(0).ShouldBe(1.0);
        clip.FadeMultiplier(50).ShouldBe(1.0);
        clip.FadeMultiplier(100).ShouldBe(1.0);
    }

    [Fact]
    public void FadeMultiplierIsZeroOutsideClipRange()
    {
        var clip = Fixtures.Clip(start: 0, duration: 100);
        clip.FadeInFrames = 10;
        clip.FadeMultiplier(-1).ShouldBe(0);
        clip.FadeMultiplier(101).ShouldBe(0);
    }

    [Fact]
    public void LinearFadeInRampsZeroToOne()
    {
        var clip = Fixtures.Clip(start: 0, duration: 100);
        clip.FadeInFrames = 10;
        clip.FadeInInterpolation = Interpolation.Linear;
        clip.FadeMultiplier(0).ShouldBe(0);
        clip.FadeMultiplier(5).ShouldBe(0.5);
        clip.FadeMultiplier(10).ShouldBe(1.0);
        clip.FadeMultiplier(50).ShouldBe(1.0);
    }

    [Fact]
    public void SmoothFadeInUsesSmoothstep()
    {
        var clip = Fixtures.Clip(start: 0, duration: 100);
        clip.FadeInFrames = 10;
        clip.FadeInInterpolation = Interpolation.Smooth;
        clip.FadeMultiplier(0).ShouldBe(0);
        clip.FadeMultiplier(5).ShouldBe(0.5);
        clip.FadeMultiplier(10).ShouldBe(1.0);
    }

    [Fact]
    public void CombinedFadesTakeMinimumOfInAndOut()
    {
        var clip = Fixtures.Clip(start: 0, duration: 100);
        clip.FadeInFrames = 20;
        clip.FadeOutFrames = 20;
        clip.FadeInInterpolation = Interpolation.Linear;
        clip.FadeOutInterpolation = Interpolation.Linear;
        clip.FadeMultiplier(0).ShouldBe(0);
        clip.FadeMultiplier(100).ShouldBe(0);
        clip.FadeMultiplier(50).ShouldBe(1.0);
    }

    // MARK: volumeAt

    [Fact]
    public void VolumeAtReturnsStaticVolumeWithoutFadeOrKfs()
    {
        var clip = Fixtures.Clip(start: 0, duration: 100, volume: 0.5);
        clip.VolumeAt(50).ShouldBe(0.5);
    }

    [Fact]
    public void VolumeAtMultipliesStaticVolumeByFade()
    {
        var clip = Fixtures.Clip(start: 0, duration: 100, volume: 0.5);
        clip.FadeInFrames = 10;
        clip.FadeInInterpolation = Interpolation.Linear;
        // fade at frame 5 = 0.5; static volume = 0.5 -> 0.25.
        Math.Abs(clip.VolumeAt(5) - 0.25).ShouldBeLessThan(1e-9);
    }

    // MARK: opacityAt + rawOpacityAt

    [Fact]
    public void OpacityAtReturnsStaticOpacityWithoutFade()
    {
        var clip = Fixtures.Clip(start: 0, duration: 100);
        clip.Opacity = 0.5;
        clip.OpacityAt(50).ShouldBe(0.5);
    }

    [Fact]
    public void OpacityAtMultipliesStaticOpacityByFade()
    {
        var clip = Fixtures.Clip(start: 0, duration: 100);
        clip.Opacity = 0.5;
        clip.FadeInFrames = 10;
        clip.FadeInInterpolation = Interpolation.Linear;
        Math.Abs(clip.OpacityAt(5) - 0.25).ShouldBeLessThan(1e-9);
    }

    [Fact]
    public void OpacityAtMultipliesKeyframedOpacityByFade()
    {
        var clip = Fixtures.Clip(start: 0, duration: 100);
        clip.Opacity = 1.0;
        clip.OpacityTrack = new KeyframeTrack<double>([
            new Keyframe<double>(0, 0.4),
            new Keyframe<double>(100, 0.4),
        ]);
        clip.FadeOutFrames = 20;
        clip.FadeOutInterpolation = Interpolation.Linear;
        // At frame 90: keyframed opacity = 0.4, fadeOut multiplier = 0.5 -> 0.2.
        Math.Abs(clip.OpacityAt(90) - 0.2).ShouldBeLessThan(1e-9);
    }

    [Fact]
    public void OpacityAtIgnoresFadeForAudioClips()
    {
        // Audio clips share the same fade fields as visual clips, but fades modulate volume
        // there — opacity should stay at the authored value.
        var clip = Fixtures.Clip(mediaType: ClipType.Audio, start: 0, duration: 100);
        clip.Opacity = 1.0;
        clip.FadeInFrames = 10;
        clip.FadeInInterpolation = Interpolation.Linear;
        clip.OpacityAt(5).ShouldBe(1.0);
    }

    [Fact]
    public void RawOpacityAtIgnoresFade()
    {
        // Round-trip guard for the inspector / stampKeyframe path: rawOpacityAt must return the
        // authored value even when a fade would zero it visually.
        var clip = Fixtures.Clip(start: 0, duration: 100);
        clip.Opacity = 1.0;
        clip.FadeInFrames = 10;
        clip.FadeInInterpolation = Interpolation.Linear;
        clip.RawOpacityAt(0).ShouldBe(1.0);
        clip.RawOpacityAt(5).ShouldBe(1.0);
        clip.OpacityAt(5).ShouldBe(0.5);
    }

    // MARK: clampFadesToDuration / setFade

    [Fact]
    public void ClampClipsFadesToDuration()
    {
        var clip = Fixtures.Clip(start: 0, duration: 100);
        clip.FadeInFrames = 80;
        clip.FadeOutFrames = 80;
        clip.ClampFadesToDuration();
        clip.FadeInFrames.ShouldBe(80);
        clip.FadeOutFrames.ShouldBe(20); // clamps to remainder after fadeIn: 100 - 80 = 20.
    }

    [Fact]
    public void SetFadeWritesEdgeFields()
    {
        var clip = Fixtures.Clip(start: 0, duration: 100);
        clip.SetFade(FadeEdge.Left, 25);
        clip.SetFade(FadeEdge.Right, 30);
        clip.FadeInFrames.ShouldBe(25);
        clip.FadeOutFrames.ShouldBe(30);
    }

    [Fact]
    public void SetDurationClampsAllKeyframeTracks()
    {
        var clip = Fixtures.Clip(start: 0, duration: 100);
        clip.OpacityTrack = new KeyframeTrack<double>([new Keyframe<double>(90, 0.5)]);
        clip.PositionTrack = new KeyframeTrack<AnimPair>([new Keyframe<AnimPair>(90, new AnimPair(0.1, 0.2))]);
        clip.ScaleTrack = new KeyframeTrack<AnimPair>([new Keyframe<AnimPair>(90, new AnimPair(0.5, 0.5))]);
        clip.RotationTrack = new KeyframeTrack<double>([new Keyframe<double>(90, 15)]);
        clip.CropTrack = new KeyframeTrack<Crop>([new Keyframe<Crop>(90, new Crop { Left = 0.1 })]);
        clip.VolumeTrack = new KeyframeTrack<double>([new Keyframe<double>(90, -6)]);

        clip.SetDuration(30);

        clip.OpacityTrack.ShouldBeNull();
        clip.PositionTrack.ShouldBeNull();
        clip.ScaleTrack.ShouldBeNull();
        clip.RotationTrack.ShouldBeNull();
        clip.CropTrack.ShouldBeNull();
        clip.VolumeTrack.ShouldBeNull();
    }
}

public class ClipMathAdversarialTests
{
    /// Cross-API consistency probe: Contains uses `< endFrame` (exclusive), and so does
    /// TimelineFrame — both agree endFrame itself is out of range.
    [Fact]
    public void ClipContainsAndTimelineFrameAgreeAtEndFrame()
    {
        var clip = Fixtures.Clip(start: 0, duration: 30);
        var containsEnd = clip.Contains(30);
        var mappedEnd = clip.TimelineFrame(1.0, 30);
        if (containsEnd)
        {
            mappedEnd.ShouldBe(30, "contains says endFrame is inside but TimelineFrame won't map to it");
        }
        else
        {
            mappedEnd.ShouldBeNull();
        }
    }

    [Fact]
    public void EndFrameIsExclusive()
    {
        var clip = Fixtures.Clip(start: 0, duration: 30);
        clip.Contains(30).ShouldBeFalse();
    }

    [Fact]
    public void ZeroDurationClipDoesNotCrashFadeMultiplier()
    {
        var clip = Fixtures.Clip(start: 0, duration: 0);
        clip.FadeInFrames = 5;
        clip.FadeInInterpolation = Interpolation.Linear;
        _ = clip.FadeMultiplier(0);
        _ = clip.FadeMultiplier(-1);
        _ = clip.FadeMultiplier(1);
    }

    [Fact]
    public void ZeroSpeedDoesNotDivideByZeroInTimelineFrame()
    {
        // The implementation guards with `Math.Max(speed, 0.0001)` — verify no crash.
        var clip = Fixtures.Clip(start: 0, duration: 100, speed: 0);
        _ = clip.TimelineFrame(1.0, 30);
    }

    [Fact]
    public void NegativeStartFrameProducesNegativeEndFrame()
    {
        var clip = Fixtures.Clip(start: -50, duration: 30);
        clip.EndFrame.ShouldBe(-20);
        clip.Contains(-40).ShouldBeTrue();
        clip.Contains(0).ShouldBeFalse();
    }
}

public class TimelineInvariantTests
{
    [Fact]
    public void TimelineTotalFramesEqualsMaximumTrackEndFrame()
    {
        var timeline = Fixtures.Timeline(tracks:
        [
            Fixtures.VideoTrack(clips: [Fixtures.Clip(start: 0, duration: 50)]),
            Fixtures.AudioTrack(clips: [Fixtures.Clip(start: 100, duration: 80)]),
        ]);
        var manualMax = timeline.Tracks.Select(t => t.EndFrame).DefaultIfEmpty(0).Max();
        timeline.TotalFrames.ShouldBe(manualMax);
    }

    [Fact]
    public void EmptyTimelineHasZeroTotalFrames()
    {
        var timeline = Fixtures.Timeline(tracks: []);
        timeline.TotalFrames.ShouldBe(0);
    }
}
