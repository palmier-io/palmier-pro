using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.Editor;

/// Mirrors Tests/PalmierProTests/Timeline/ClipMutationsTests.swift's `StampKeyframeTests` plus the
/// drag-move/interpolation surface ClipMutationsTests.cs's own doc comment flagged as deferred to
/// M5 ("stampKeyframe ... are M5 Inspector concerns and are not ported here"). Covers
/// TimelineEditorViewModel.Keyframes.cs — the Inspector Keyframes tab's mutation surface.
public class StampKeyframeTests
{
    [Fact]
    public async Task OpacityStoresAuthoredValueNotFadedValue()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 100);
        clip.Opacity = 1.0;
        clip.FadeInFrames = 10;
        clip.FadeInInterpolation = Interpolation.Linear;
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.StampKeyframe("c1", AnimatableProperty.Opacity, 5);

        var kf = e.Timeline.Tracks[0].Clips[0].OpacityTrack!.Keyframes[0];
        kf.Frame.ShouldBe(5);
        kf.Value.ShouldBe(1.0);
    }

    [Fact]
    public async Task DefaultsToCurrentFrameWhenFrameOmitted()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 100);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        e.CurrentFrame = 20;

        e.StampKeyframe("c1", AnimatableProperty.Rotation);

        e.Timeline.Tracks[0].Clips[0].RotationTrack!.Keyframes[0].Frame.ShouldBe(20);
    }

    [Fact]
    public async Task IsNoOpWhenFrameOutsideClipRange()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 30);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.StampKeyframe("c1", AnimatableProperty.Opacity, 100);

        e.Timeline.Tracks[0].Clips[0].OpacityTrack.ShouldBeNull();
    }

    [Fact]
    public async Task RegistersUndoableActionNamedAddKeyframe()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 30);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.StampKeyframe("c1", AnimatableProperty.Opacity, 5);

        e.Document.UndoService.CanUndo.ShouldBeTrue();
        e.Document.UndoService.UndoActionName.ShouldBe("Add Keyframe");
        e.Document.UndoService.Undo();
        e.Timeline.Tracks[0].Clips[0].OpacityTrack.ShouldBeNull();
    }
}

public class RemoveKeyframeTests
{
    [Fact]
    public async Task DeletesAnExistingKeyframe()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 30);
        clip.OpacityTrack = new KeyframeTrack<double>([new Keyframe<double>(5, 0.5)]);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.RemoveKeyframe("c1", AnimatableProperty.Opacity, 5);

        e.Timeline.Tracks[0].Clips[0].OpacityTrack.ShouldBeNull();
    }

    [Fact]
    public async Task UndoRestoresTheDeletedKeyframe()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 30);
        clip.OpacityTrack = new KeyframeTrack<double>([new Keyframe<double>(5, 0.5)]);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.RemoveKeyframe("c1", AnimatableProperty.Opacity, 5);
        e.Document.UndoService.UndoActionName.ShouldBe("Delete Keyframe");
        e.Document.UndoService.Undo();

        e.Timeline.Tracks[0].Clips[0].OpacityTrack!.Keyframes[0].Value.ShouldBe(0.5);
    }
}

public class SetKeyframeInterpolationTests
{
    [Fact]
    public async Task ChangesInterpolationOutForTheGivenFrame()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 30);
        clip.OpacityTrack = new KeyframeTrack<double>([new Keyframe<double>(5, 0.5, Interpolation.Smooth)]);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.SetKeyframeInterpolation("c1", AnimatableProperty.Opacity, 5, Interpolation.Hold);

        e.Timeline.Tracks[0].Clips[0].OpacityTrack!.Keyframes[0].InterpolationOut.ShouldBe(Interpolation.Hold);
        e.Document.UndoService.UndoActionName.ShouldBe("Change Interpolation");
    }
}

public class MoveKeyframeTests
{
    [Fact]
    public async Task ApplyMoveKeyframeMovesLiveWithoutRegisteringUndo()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 30);
        clip.OpacityTrack = new KeyframeTrack<double>([new Keyframe<double>(5, 0.5)]);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.ApplyMoveKeyframe("c1", AnimatableProperty.Opacity, 5, 10);

        e.Timeline.Tracks[0].Clips[0].OpacityTrack!.Keyframes[0].Frame.ShouldBe(10);
        e.Document.UndoService.CanUndo.ShouldBeFalse();
    }

    [Fact]
    public async Task CommitMoveKeyframeRegistersSingleUndoStep()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 30);
        clip.OpacityTrack = new KeyframeTrack<double>([new Keyframe<double>(5, 0.5)]);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.ApplyMoveKeyframe("c1", AnimatableProperty.Opacity, 5, 10);
        e.ApplyMoveKeyframe("c1", AnimatableProperty.Opacity, 10, 15);
        e.CommitMoveKeyframe("c1");

        e.Timeline.Tracks[0].Clips[0].OpacityTrack!.Keyframes[0].Frame.ShouldBe(15);
        e.Document.UndoService.CanUndo.ShouldBeTrue();
        e.Document.UndoService.UndoActionName.ShouldBe("Move Keyframe");

        e.Document.UndoService.Undo();
        e.Timeline.Tracks[0].Clips[0].OpacityTrack!.Keyframes[0].Frame.ShouldBe(5);
    }

    [Fact]
    public async Task CommitMoveKeyframeWithNoNetMoveRegistersNothing()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 30);
        clip.OpacityTrack = new KeyframeTrack<double>([new Keyframe<double>(5, 0.5)]);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.ApplyMoveKeyframe("c1", AnimatableProperty.Opacity, 5, 10);
        e.ApplyMoveKeyframe("c1", AnimatableProperty.Opacity, 10, 5);
        e.CommitMoveKeyframe("c1");

        e.Document.UndoService.CanUndo.ShouldBeFalse();
    }

    [Fact]
    public async Task CancelMoveKeyframeDragRevertsTheLiveEdit()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 30);
        clip.OpacityTrack = new KeyframeTrack<double>([new Keyframe<double>(5, 0.5)]);
        var (e, temp) = await EditorFixtures.MakeAsync([EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        e.ApplyMoveKeyframe("c1", AnimatableProperty.Opacity, 5, 10);
        e.CancelMoveKeyframeDrag("c1");

        e.Timeline.Tracks[0].Clips[0].OpacityTrack!.Keyframes[0].Frame.ShouldBe(5);
        e.Document.UndoService.CanUndo.ShouldBeFalse();
    }
}
