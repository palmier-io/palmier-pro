using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

/// Mirrors Tests/PalmierProTests/Timeline/KeyframeTests.swift.
public class KeyframeTrackMutationTests
{
    [Fact]
    public void UpsertIntoEmptyAppends()
    {
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double>(10, 1.0));
        track.Keyframes.Count.ShouldBe(1);
        track.Keyframes[0].Frame.ShouldBe(10);
        track.IsActive.ShouldBeTrue();
    }

    [Fact]
    public void UpsertMaintainsSortedOrder()
    {
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double>(20, 2.0));
        track.Upsert(new Keyframe<double>(5, 0.5));
        track.Upsert(new Keyframe<double>(10, 1.0));
        track.Keyframes.Select(k => k.Frame).ShouldBe([5, 10, 20]);
    }

    [Fact]
    public void UpsertReplacesKeyframeAtSameFrame()
    {
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double>(10, 1.0));
        track.Upsert(new Keyframe<double>(10, 99.0));
        track.Keyframes.Count.ShouldBe(1);
        track.Keyframes[0].Value.ShouldBe(99.0);
    }

    [Fact]
    public void RemoveDeletesAtFrame()
    {
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double>(5, 0.5));
        track.Upsert(new Keyframe<double>(10, 1.0));
        track.Remove(5);
        track.Keyframes.Select(k => k.Frame).ShouldBe([10]);
    }

    [Fact]
    public void RemoveAtMissingFrameIsNoOp()
    {
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double>(10, 1.0));
        track.Remove(99);
        track.Keyframes.Count.ShouldBe(1);
    }

    [Fact]
    public void EmptyTrackIsNotActive()
    {
        new KeyframeTrack<double>().IsActive.ShouldBeFalse();
    }

    [Fact]
    public void MoveRelocatesKeyframeAndMaintainsOrder()
    {
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double>(5, 0.5));
        track.Upsert(new Keyframe<double>(10, 1.0));
        track.Upsert(new Keyframe<double>(20, 2.0));
        track.Move(5, 15); // 0.5 moves between 1.0 and 2.0
        track.Keyframes.Select(k => k.Frame).ShouldBe([10, 15, 20]);
        track.Keyframes[1].Value.ShouldBe(0.5);
    }

    [Fact]
    public void MoveFromMissingFrameIsNoOp()
    {
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double>(10, 1.0));
        track.Move(99, 5);
        track.Keyframes.Select(k => k.Frame).ShouldBe([10]);
    }

    [Fact]
    public void MoveOntoExistingFrameIsRefused()
    {
        // Move() refuses when the destination is occupied — both keyframes survive unchanged.
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double>(5, 0.5));
        track.Upsert(new Keyframe<double>(10, 1.0));
        track.Move(5, 10);
        track.Keyframes.Count.ShouldBe(2);
        track.Keyframes.First(k => k.Frame == 5).Value.ShouldBe(0.5);
        track.Keyframes.First(k => k.Frame == 10).Value.ShouldBe(1.0);
    }

    [Fact]
    public void MoveOntoSameFrameIsNoOp()
    {
        // Edge case: moving a keyframe onto its own frame must not refuse itself.
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double>(10, 0.5));
        track.Move(10, 10);
        track.Keyframes.Count.ShouldBe(1);
        track.Keyframes[0].Value.ShouldBe(0.5);
    }
}

public class KeyframeTrackSampleTests
{
    [Fact]
    public void EmptyTrackReturnsFallback()
    {
        var track = new KeyframeTrack<double>();
        track.Sample(10, 42.0, KeyframeInterpolation.Double).ShouldBe(42.0);
    }

    [Fact]
    public void SingleKeyframeReturnsItsValueEverywhere()
    {
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double>(10, 7.0));
        track.Sample(0, 0, KeyframeInterpolation.Double).ShouldBe(7.0);
        track.Sample(10, 0, KeyframeInterpolation.Double).ShouldBe(7.0);
        track.Sample(100, 0, KeyframeInterpolation.Double).ShouldBe(7.0);
    }

    [Fact]
    public void SamplesBeforeFirstClampToFirstValue()
    {
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double>(10, 1.0));
        track.Upsert(new Keyframe<double>(20, 2.0));
        track.Sample(5, 0, KeyframeInterpolation.Double).ShouldBe(1.0);
        track.Sample(10, 0, KeyframeInterpolation.Double).ShouldBe(1.0);
    }

    [Fact]
    public void SamplesAfterLastClampToLastValue()
    {
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double>(10, 1.0));
        track.Upsert(new Keyframe<double>(20, 2.0));
        track.Sample(20, 0, KeyframeInterpolation.Double).ShouldBe(2.0);
        track.Sample(100, 0, KeyframeInterpolation.Double).ShouldBe(2.0);
    }

    [Fact]
    public void LinearInterpolatesBetweenKeyframes()
    {
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double>(0, 0, Interpolation.Linear));
        track.Upsert(new Keyframe<double>(10, 10));
        track.Sample(3, 0, KeyframeInterpolation.Double).ShouldBe(3.0);
        track.Sample(5, 0, KeyframeInterpolation.Double).ShouldBe(5.0);
        track.Sample(7, 0, KeyframeInterpolation.Double).ShouldBe(7.0);
    }

    [Fact]
    public void HoldReturnsLeftKeyframeUntilNextStarts()
    {
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double>(0, 0, Interpolation.Hold));
        track.Upsert(new Keyframe<double>(10, 10));
        track.Sample(1, 0, KeyframeInterpolation.Double).ShouldBe(0.0);
        track.Sample(9, 0, KeyframeInterpolation.Double).ShouldBe(0.0);
        track.Sample(10, 0, KeyframeInterpolation.Double).ShouldBe(10.0);
    }

    [Fact]
    public void SmoothUsesSmoothstepEasing()
    {
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double>(0, 0, Interpolation.Smooth));
        track.Upsert(new Keyframe<double>(10, 10));
        // smoothstep(0.5) = 0.5 -> same as linear at midpoint.
        track.Sample(5, 0, KeyframeInterpolation.Double).ShouldBe(5.0);
        // smoothstep(0.1) = 0.028 -> 0.28. Easing is slower at the ends than linear (would be 1.0).
        var early = track.Sample(1, 0, KeyframeInterpolation.Double);
        early.ShouldBeLessThan(1.0);
        early.ShouldBeGreaterThan(0);
    }

    [Fact]
    public void InterpolationOutBelongsToLeftKeyframe()
    {
        // The interpolation on the SECOND keyframe doesn't affect the segment before it.
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double>(0, 0, Interpolation.Linear));
        track.Upsert(new Keyframe<double>(10, 10, Interpolation.Hold));
        track.Sample(5, 0, KeyframeInterpolation.Double).ShouldBe(5.0);
    }
}

public class InterpolationPrimitiveTests
{
    [Fact]
    public void SmoothstepEndpointsAreZeroAndOne()
    {
        KeyframeInterpolation.SmoothStep(0).ShouldBe(0.0);
        KeyframeInterpolation.SmoothStep(1).ShouldBe(1.0);
    }

    [Fact]
    public void SmoothstepMidpointIsHalf()
    {
        KeyframeInterpolation.SmoothStep(0.5).ShouldBe(0.5);
    }

    [Fact]
    public void SmoothstepFlattensNearEdges()
    {
        KeyframeInterpolation.SmoothStep(0.1).ShouldBeLessThan(0.1);
        KeyframeInterpolation.SmoothStep(0.9).ShouldBeGreaterThan(0.9);
    }

    [Fact]
    public void DoubleInterpolationIsLinear()
    {
        KeyframeInterpolation.Double(0, 10, 0.25).ShouldBe(2.5);
        KeyframeInterpolation.Double(-5, 5, 0.5).ShouldBe(0);
    }

    [Fact]
    public void AnimPairInterpolatesBothComponentsIndependently()
    {
        var result = KeyframeInterpolation.AnimPair(new AnimPair(0, 100), new AnimPair(10, 200), 0.5);
        result.A.ShouldBe(5);
        result.B.ShouldBe(150);
    }

    [Fact]
    public void CropInterpolatesAllFourInsets()
    {
        var a = new Crop { Left = 0, Top = 0, Right = 0, Bottom = 0 };
        var b = new Crop { Left = 1, Top = 1, Right = 1, Bottom = 1 };
        var result = KeyframeInterpolation.Crop(a, b, 0.25);
        result.Left.ShouldBe(0.25);
        result.Top.ShouldBe(0.25);
        result.Right.ShouldBe(0.25);
        result.Bottom.ShouldBe(0.25);
    }
}

public class KeyframeAdversarialTests
{
    [Fact]
    public void TrackStaysSortedAcrossScrambledUpserts()
    {
        var track = new KeyframeTrack<double>();
        int[] order = [50, 10, 90, 30, 70, 0, 40, 20, 80, 60];
        foreach (var f in order)
        {
            track.Upsert(new Keyframe<double>(f, f));
        }
        var frames = track.Keyframes.Select(k => k.Frame).ToList();
        frames.ShouldBe(frames.OrderBy(f => f));
    }

    [Fact]
    public void UpsertCollapsesRepeatedSameFrameWrites()
    {
        var track = new KeyframeTrack<double>();
        foreach (var v in new[] { 1.0, 2.0, 3.0, 4.0 })
        {
            track.Upsert(new Keyframe<double>(10, v));
        }
        track.Keyframes.Count.ShouldBe(1);
        track.Keyframes[0].Value.ShouldBe(4.0); // last-write-wins
    }

    [Fact]
    public void SmoothstepStaysInUnitIntervalForUnitInputs()
    {
        for (var t = 0.0; t <= 1.0; t += 0.05)
        {
            var s = KeyframeInterpolation.SmoothStep(t);
            (s >= 0 && s <= 1).ShouldBeTrue($"smoothstep({t}) = {s} escaped [0, 1]");
        }
    }

    [Fact]
    public void SmoothstepIsMonotonicallyNonDecreasingOnUnitInterval()
    {
        var prev = KeyframeInterpolation.SmoothStep(0);
        for (var i = 1; i <= 100; i++)
        {
            var t = i / 100.0;
            var s = KeyframeInterpolation.SmoothStep(t);
            s.ShouldBeGreaterThanOrEqualTo(prev);
            prev = s;
        }
    }

    [Fact]
    public void TrackAcceptsNegativeFramesAndStaysSorted()
    {
        var track = new KeyframeTrack<double>();
        track.Upsert(new Keyframe<double>(-10, 0));
        track.Upsert(new Keyframe<double>(10, 1));
        track.Upsert(new Keyframe<double>(-5, 0.5));
        track.Keyframes.Select(k => k.Frame).ShouldBe([-10, -5, 10]);
    }
}
