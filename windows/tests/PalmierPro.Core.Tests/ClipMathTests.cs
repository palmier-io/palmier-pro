using PalmierPro.Core.Models;
using Xunit;

namespace PalmierPro.Core.Tests;

public class ClipMathTests
{
    private static Clip MakeClip(int start = 0, int duration = 100) => new()
    {
        MediaRef = "M",
        StartFrame = start,
        DurationFrames = duration,
    };

    [Fact]
    public void KeyframeSamplingInterpolatesLinearly()
    {
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double> { Frame = 0, Value = 0, InterpolationOut = Interpolation.Linear });
        track.Upsert(new Keyframe<double> { Frame = 10, Value = 1 });

        Assert.Equal(0.5, track.Sample(5, 99));
        Assert.Equal(0, track.Sample(-5, 99));
        Assert.Equal(1, track.Sample(50, 99));
    }

    [Fact]
    public void KeyframeSamplingHoldsUntilNextKeyframe()
    {
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double> { Frame = 0, Value = 2, InterpolationOut = Interpolation.Hold });
        track.Upsert(new Keyframe<double> { Frame = 10, Value = 8 });

        Assert.Equal(2, track.Sample(9, 0));
        Assert.Equal(8, track.Sample(10, 0));
    }

    [Fact]
    public void KeyframeSamplingSmoothstepMatchesSwift()
    {
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double> { Frame = 0, Value = 0, InterpolationOut = Interpolation.Smooth });
        track.Upsert(new Keyframe<double> { Frame = 10, Value = 1 });

        // smoothstep(0.5) = 0.5, smoothstep(0.2) = 0.104
        Assert.Equal(0.5, track.Sample(5, 0), 12);
        Assert.Equal(0.104, track.Sample(2, 0), 12);
    }

    [Fact]
    public void UpsertKeepsKeyframesSortedAndReplacesSameFrame()
    {
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double> { Frame = 10, Value = 1 });
        track.Upsert(new Keyframe<double> { Frame = 0, Value = 0 });
        track.Upsert(new Keyframe<double> { Frame = 5, Value = 0.5 });
        track.Upsert(new Keyframe<double> { Frame = 5, Value = 0.75 });

        Assert.Equal([0, 5, 10], track.Keyframes.Select(k => k.Frame));
        Assert.Equal(0.75, track.Keyframes[1].Value);
    }

    [Fact]
    public void MoveRefusesOccupiedTargetFrame()
    {
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double> { Frame = 0, Value = 0 });
        track.Upsert(new Keyframe<double> { Frame = 10, Value = 1 });

        track.Move(0, 10);
        Assert.Equal([0, 10], track.Keyframes.Select(k => k.Frame));
    }

    [Fact]
    public void FadeMultiplierRampsBothEdges()
    {
        var clip = MakeClip(duration: 100);
        clip.FadeInFrames = 10;
        clip.FadeOutFrames = 20;

        Assert.Equal(0.5, clip.FadeMultiplier(5), 12);
        Assert.Equal(1.0, clip.FadeMultiplier(50), 12);
        Assert.Equal(0.5, clip.FadeMultiplier(90), 12);
        Assert.Equal(0, clip.FadeMultiplier(-1));
        Assert.Equal(0, clip.FadeMultiplier(101));
    }

    [Fact]
    public void VolumeCombinesKeyframeEnvelopeFadeAndStaticGain()
    {
        var clip = MakeClip(duration: 100);
        clip.Volume = 0.5;
        clip.UpsertKeyframe(AnimatableProperty.Volume, 0, 0.0); // 0 dB → gain 1

        Assert.Equal(0.5, clip.VolumeAt(50), 12);

        clip.FadeInFrames = 10;
        Assert.Equal(0.25, clip.VolumeAt(5), 12);
    }

    [Fact]
    public void OpacityAtIgnoresFadesForAudio()
    {
        var clip = MakeClip(duration: 100);
        clip.MediaType = ClipType.Audio;
        clip.FadeInFrames = 10;
        clip.Opacity = 0.8;
        Assert.Equal(0.8, clip.OpacityAt(0), 12);
    }

    [Fact]
    public void ClampFadesRespectsDurationAndPriority()
    {
        var clip = MakeClip(duration: 30);
        clip.FadeInFrames = 25;
        clip.FadeOutFrames = 25;
        clip.ClampFadesToDuration();
        Assert.Equal(25, clip.FadeInFrames);
        Assert.Equal(5, clip.FadeOutFrames);
    }

    [Fact]
    public void SetDurationRescalesWordTimingsAndDropsOutOfRangeKeyframes()
    {
        var clip = MakeClip(duration: 100);
        clip.MediaType = ClipType.Text;
        clip.WordTimings = [new WordTiming("hi", 0, 50), new WordTiming("there", 50, 100)];
        clip.UpsertKeyframe(AnimatableProperty.Opacity, 90, 0.5);

        clip.SetDuration(50);

        Assert.Equal(25, clip.WordTimings[0].EndFrame);
        Assert.Equal(50, clip.WordTimings[1].EndFrame);
        Assert.Null(clip.OpacityTrack);
    }

    [Fact]
    public void SourceFrameMathRoundsLikeSwift()
    {
        var clip = MakeClip(duration: 100);
        clip.Speed = 1.5;
        Assert.Equal(150, clip.SourceFramesConsumed);
        clip.TrimStartFrame = 10;
        clip.TrimEndFrame = 5;
        Assert.Equal(165, clip.SourceDurationFrames);
    }

    [Fact]
    public void TimelineFrameMapsSourceSecondsThroughTrimAndSpeed()
    {
        var clip = MakeClip(start: 100, duration: 100);
        clip.TrimStartFrame = 30;
        clip.Speed = 2.0;

        // source frame 60 → offsetFromTrim 30 → timeline 100 + 15
        Assert.Equal(115, clip.TimelineFrame(2.0, 30));
        Assert.Null(clip.TimelineFrame(0.5, 30));  // before trim
        Assert.Null(clip.TimelineFrame(100, 30));  // past clip end
    }

    [Fact]
    public void RebasedInsertsBoundaryKeyframe()
    {
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double> { Frame = 0, Value = 0, InterpolationOut = Interpolation.Linear });
        track.Upsert(new Keyframe<double> { Frame = 10, Value = 1, InterpolationOut = Interpolation.Linear });

        var rebased = track.Rebased(5, 42)!;
        Assert.Equal(0, rebased.Keyframes[0].Frame);
        Assert.Equal(0.5, rebased.Keyframes[0].Value, 12);
        Assert.Equal(5, rebased.Keyframes[1].Frame);
        Assert.Equal(1, rebased.Keyframes[1].Value);
    }

    [Fact]
    public void FreshenIdsRemapsGroupsConsistently()
    {
        var groups = new Dictionary<string, string>();
        var a = MakeClip();
        a.LinkGroupId = "L1";
        var b = MakeClip();
        b.LinkGroupId = "L1";

        a.FreshenIds(groups);
        b.FreshenIds(groups);

        Assert.NotEqual("L1", a.LinkGroupId);
        Assert.Equal(a.LinkGroupId, b.LinkGroupId);
        Assert.NotEqual(a.Id, b.Id);
    }

    [Fact]
    public void ContiguousClipChainStopsAtGap()
    {
        var track = new Track { Type = ClipType.Video };
        track.Clips.Add(new Clip { Id = "A", MediaRef = "M", StartFrame = 0, DurationFrames = 10 });
        track.Clips.Add(new Clip { Id = "B", MediaRef = "M", StartFrame = 10, DurationFrames = 10 });
        track.Clips.Add(new Clip { Id = "C", MediaRef = "M", StartFrame = 25, DurationFrames = 10 });

        var ids = track.ContiguousClipIds(0, excludeId: "X");
        Assert.Equal(new HashSet<string> { "A", "B" }, ids);
    }

    [Fact]
    public void GradeCurveEvalClampsOutsideRange()
    {
        var pts = new List<CurvePoint> { new(0.2, 0.1), new(0.8, 0.9) };
        Assert.Equal(0.1, GradeCurve.Eval(pts, 0));
        Assert.Equal(0.9, GradeCurve.Eval(pts, 1));
        Assert.Equal(0.5, GradeCurve.Eval(pts, 0.5), 12);
    }

    [Fact]
    public void HueCurvesEvalWrapsAroundSeam()
    {
        var pts = new List<CurvePoint> { new(0.25, 0.6), new(0.75, 0.4) };
        // At x=0 (before first point) interpolation wraps from (0.75-1, 0.4).
        var expected = 0.4 + (0.6 - 0.4) * ((0 - -0.25) / (0.25 - -0.25));
        Assert.Equal(expected, HueCurves.Eval(pts, 0), 12);
    }

    [Fact]
    public void VolumeScaleConvertsSymmetrically()
    {
        Assert.Equal(0, VolumeScale.LinearFromDb(-60));
        Assert.Equal(1, VolumeScale.LinearFromDb(0), 12);
        Assert.Equal(-60, VolumeScale.DbFromLinear(0));
        Assert.Equal(0, VolumeScale.DbFromLinear(1), 12);
        Assert.Equal(6.0, VolumeScale.DbFromLinear(VolumeScale.LinearFromDb(6.0)), 9);
    }
}
