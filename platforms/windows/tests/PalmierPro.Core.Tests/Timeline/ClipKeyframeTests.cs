using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

/// Mirrors Tests/PalmierProTests/Timeline/ClipKeyframeExtensionTests.swift. Clip stores keyframes
/// by clip-relative offset; the inspector and other callers work in absolute timeline frames.
/// These tests verify the translation through every public API. The Windows port exposes one
/// Upsert method per property (UpsertOpacityKeyframe, UpsertScaleKeyframe, ...) rather than the
/// Mac's single generic `upsertKeyframe(in:frame:value:)` keypath overload — same semantics,
/// property-specific entry points instead of a WritableKeyPath parameter (no C# equivalent).
public class ClipKeyframeTests
{
    // MARK: - KeyframeFrames + AllKeyframeFrames

    [Fact]
    public void KeyframeFramesAreAbsoluteNotClipRelative()
    {
        var clip = Fixtures.Clip(start: 100, duration: 60);
        clip.UpsertOpacityKeyframe(110, 0.5);
        clip.UpsertOpacityKeyframe(150, 1.0);
        // Storage offsets are 10 and 50; public API returns absolute 110 and 150.
        clip.KeyframeFrames(AnimatableProperty.Opacity).ShouldBe([110, 150]);
    }

    [Fact]
    public void KeyframeFramesReturnsEmptyForUntouchedProperty()
    {
        var clip = Fixtures.Clip(start: 0, duration: 30);
        clip.KeyframeFrames(AnimatableProperty.Opacity).ShouldBeEmpty();
        clip.KeyframeFrames(AnimatableProperty.Position).ShouldBeEmpty();
    }

    [Fact]
    public void AllKeyframeFramesIsSortedUnionAcrossProperties()
    {
        var clip = Fixtures.Clip(start: 100, duration: 100);
        clip.UpsertOpacityKeyframe(110, 1.0);
        clip.UpsertScaleKeyframe(150, new AnimPair(1, 1));
        clip.UpsertOpacityKeyframe(180, 0.5);
        clip.UpsertRotationKeyframe(110, 90); // same frame as opacity
        // Union dedupes; ascending sort.
        clip.AllKeyframeFrames().ShouldBe([110, 150, 180]);
    }

    // MARK: - Upsert*Keyframe

    [Fact]
    public void UpsertCreatesTrackIfAbsent()
    {
        var clip = Fixtures.Clip(start: 0, duration: 30);
        clip.OpacityTrack.ShouldBeNull();
        clip.UpsertOpacityKeyframe(10, 0.5);
        clip.OpacityTrack!.Keyframes.Count.ShouldBe(1);
    }

    [Fact]
    public void UpsertOnSameFrameReplacesValue()
    {
        var clip = Fixtures.Clip(start: 100, duration: 60);
        clip.UpsertOpacityKeyframe(130, 0.5);
        clip.UpsertOpacityKeyframe(130, 0.9);
        clip.OpacityTrack!.Keyframes.Count.ShouldBe(1);
        clip.OpacityTrack.Keyframes[0].Value.ShouldBe(0.9);
    }

    // MARK: - RemoveKeyframe

    [Fact]
    public void RemoveKeyframeDropsByAbsoluteFrame()
    {
        var clip = Fixtures.Clip(start: 100, duration: 60);
        clip.UpsertOpacityKeyframe(110, 0.5);
        clip.UpsertOpacityKeyframe(150, 1.0);
        clip.RemoveKeyframe(AnimatableProperty.Opacity, 110);
        clip.KeyframeFrames(AnimatableProperty.Opacity).ShouldBe([150]);
    }

    [Fact]
    public void RemoveLastKeyframeNilsTheTrack()
    {
        // The track is dropped to null when empty so IsActive checks elsewhere work correctly.
        var clip = Fixtures.Clip(start: 100, duration: 60);
        clip.UpsertOpacityKeyframe(110, 0.5);
        clip.RemoveKeyframe(AnimatableProperty.Opacity, 110);
        clip.OpacityTrack.ShouldBeNull();
    }

    [Fact]
    public void RemoveKeyframeAtMissingFrameIsNoOp()
    {
        var clip = Fixtures.Clip(start: 100, duration: 60);
        clip.UpsertOpacityKeyframe(110, 0.5);
        clip.RemoveKeyframe(AnimatableProperty.Opacity, 999); // not present
        clip.OpacityTrack!.Keyframes.Count.ShouldBe(1);
    }

    // MARK: - ClearKeyframes

    [Fact]
    public void ClearKeyframesDropsTheEntireTrack()
    {
        var clip = Fixtures.Clip(start: 0, duration: 30);
        clip.UpsertOpacityKeyframe(10, 0.5);
        clip.UpsertOpacityKeyframe(20, 1.0);
        clip.ClearKeyframes(AnimatableProperty.Opacity);
        clip.OpacityTrack.ShouldBeNull();
    }

    [Fact]
    public void ClearKeyframesOnlyAffectsTheNamedProperty()
    {
        var clip = Fixtures.Clip(start: 0, duration: 30);
        clip.UpsertOpacityKeyframe(10, 0.5);
        clip.UpsertRotationKeyframe(10, 45);
        clip.ClearKeyframes(AnimatableProperty.Opacity);
        clip.OpacityTrack.ShouldBeNull();
        clip.RotationTrack!.Keyframes.Count.ShouldBe(1);
    }

    // MARK: - SetInterpolation

    [Fact]
    public void SetInterpolationChangesNamedKeyframeOnly()
    {
        var clip = Fixtures.Clip(start: 100, duration: 60);
        clip.UpsertOpacityKeyframe(110, 0.5);
        clip.UpsertOpacityKeyframe(150, 1.0);
        clip.SetInterpolation(AnimatableProperty.Opacity, 110, Interpolation.Hold);
        clip.InterpolationAt(AnimatableProperty.Opacity, 110).ShouldBe(Interpolation.Hold);
        clip.InterpolationAt(AnimatableProperty.Opacity, 150).ShouldNotBe(Interpolation.Hold);
    }

    [Fact]
    public void SetInterpolationAtMissingFrameIsNoOp()
    {
        var clip = Fixtures.Clip(start: 100, duration: 60);
        clip.UpsertOpacityKeyframe(110, 0.5);
        clip.SetInterpolation(AnimatableProperty.Opacity, 999, Interpolation.Linear);
        // Original kf unchanged.
        clip.InterpolationAt(AnimatableProperty.Opacity, 110).ShouldBe(Interpolation.Smooth);
    }

    // MARK: - MoveKeyframe

    [Fact]
    public void MoveKeyframeRelocatesByAbsoluteFrame()
    {
        var clip = Fixtures.Clip(start: 100, duration: 60);
        clip.UpsertOpacityKeyframe(110, 0.5);
        clip.MoveKeyframe(AnimatableProperty.Opacity, 110, 140);
        clip.KeyframeFrames(AnimatableProperty.Opacity).ShouldBe([140]);
    }

    [Fact]
    public void MoveKeyframeOntoExistingFrameIsRefused()
    {
        // KeyframeTrack.Move refuses on destination collision (per the earlier decision).
        // Clip wraps this behavior — both keyframes survive.
        var clip = Fixtures.Clip(start: 100, duration: 60);
        clip.UpsertOpacityKeyframe(110, 0.5);
        clip.UpsertOpacityKeyframe(140, 1.0);
        clip.MoveKeyframe(AnimatableProperty.Opacity, 110, 140);
        clip.OpacityTrack!.Keyframes.Count.ShouldBe(2);
        clip.KeyframeFrames(AnimatableProperty.Opacity).ShouldBe([110, 140]);
    }
}
