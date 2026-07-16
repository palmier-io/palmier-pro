using PalmierPro.App.Editing;
using PalmierPro.App.Tests.ViewModels.Editor;
using PalmierPro.App.ViewModels.Inspector;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.Inspector;

/// Covers KeyframesViewModel — the Keyframes tab's read/glue surface (row list, snap targets,
/// playhead/clip metadata) plus the drag-to-move gesture. Ports the read half of
/// Inspector/Keyframes/KeyframesLane.swift and the keyframe-mutation slice of
/// Tests/PalmierProTests/Timeline/KeyframeTests.swift's KeyframeTrack move/upsert/remove suites,
/// now exercised through TimelineEditorViewModel's undoable wrappers.
public class KeyframesViewModelTests
{
    [Fact]
    public async Task RowsListsTheFiveVideoPropertiesInLaneOrder()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;

        KeyframesViewModel.Rows.Select(r => r.Property).ShouldBe([
            AnimatableProperty.Position, AnimatableProperty.Scale, AnimatableProperty.Rotation,
            AnimatableProperty.Opacity, AnimatableProperty.Crop,
        ]);
    }

    [Fact]
    public async Task ClipLabelResolvesTheMediaManifestDisplayName()
    {
        var clip = EditorFixtures.Clip(id: "c1", mediaRef: "media-1", start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        e.Document.Manifest.Entries.Add(new MediaManifestEntry(
            "media-1", "Beach Shot.mov", ClipType.Video, MediaSource.External("C:/beach.mov"), 10));
        var vm = new KeyframesViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        vm.ClipLabel.ShouldBe("Beach Shot.mov");
    }

    [Fact]
    public async Task ClipFrameMetadataReflectsTheSelectedClip()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 10, duration: 30);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new KeyframesViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        vm.ClipStartFrame.ShouldBe(10);
        vm.ClipEndFrame.ShouldBe(40);
        vm.ClipSpanFrames.ShouldBe(30);
    }

    [Fact]
    public async Task PlayheadInRangeTracksTheCurrentFrameAgainstTheClipBounds()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 10, duration: 30);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new KeyframesViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        e.CurrentFrame = 5;
        vm.PlayheadInRange.ShouldBeFalse();

        e.CurrentFrame = 20;
        vm.PlayheadInRange.ShouldBeTrue();
    }

    [Fact]
    public async Task KeyframeFramesAndInterpolationAtReadFromTheClipsTrack()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        clip.OpacityTrack = new KeyframeTrack<double>([
            new Keyframe<double>(0, 1.0, Interpolation.Hold),
            new Keyframe<double>(30, 0.0),
        ]);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new KeyframesViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        vm.KeyframeFrames(AnimatableProperty.Opacity).ShouldBe([0, 30]);
        vm.HasKeyframe(AnimatableProperty.Opacity, 30).ShouldBeTrue();
        vm.PreviousKeyframeFrame(AnimatableProperty.Opacity, 30).ShouldBe(0);
        vm.NextKeyframeFrame(AnimatableProperty.Opacity, 0).ShouldBe(30);
        vm.InterpolationAt(AnimatableProperty.Opacity, 0).ShouldBe(Interpolation.Hold);
    }

    [Fact]
    public async Task SnapTargetsIncludesThePlayheadOnlyWhenItIsInsideTheClip()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 10, duration: 30);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new KeyframesViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        e.CurrentFrame = 5; // outside [10, 40)
        vm.SnapTargets(AnimatableProperty.Opacity).ShouldNotContain(t => t.Kind == SnapEngine.SnapTargetKind.Playhead);

        e.CurrentFrame = 20;
        vm.SnapTargets(AnimatableProperty.Opacity).ShouldContain(new SnapEngine.SnapTarget(20, SnapEngine.SnapTargetKind.Playhead));
    }

    [Fact]
    public async Task SnapTargetsIncludesClipEdgesAndOtherRowsKeyframesButExcludesTheOwnRow()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 10, duration: 30);
        clip.OpacityTrack = new KeyframeTrack<double>([new Keyframe<double>(5, 1.0)]); // -> abs frame 15
        clip.RotationTrack = new KeyframeTrack<double>([new Keyframe<double>(10, 45)]); // -> abs frame 20
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new KeyframesViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        var targets = vm.SnapTargets(AnimatableProperty.Opacity);

        targets.ShouldContain(new SnapEngine.SnapTarget(10, SnapEngine.SnapTargetKind.ClipEdge)); // clip start
        targets.ShouldContain(new SnapEngine.SnapTarget(40, SnapEngine.SnapTargetKind.ClipEdge)); // clip end
        targets.ShouldContain(new SnapEngine.SnapTarget(20, SnapEngine.SnapTargetKind.ClipEdge)); // rotation row's keyframe
        targets.ShouldNotContain(new SnapEngine.SnapTarget(15, SnapEngine.SnapTargetKind.ClipEdge)); // own (opacity) row excluded
    }

    [Fact]
    public async Task StampAtPlayheadCapturesTheSampledValueAndRegistersAddKeyframeUndo()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 100);
        clip.Opacity = 1.0;
        clip.FadeInFrames = 10;
        clip.FadeInInterpolation = Interpolation.Linear;
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        e.CurrentFrame = 5;
        var vm = new KeyframesViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        vm.StampAtPlayhead(AnimatableProperty.Opacity);

        var kf = e.ClipFor("c1")!.OpacityTrack!.Keyframes.Single();
        kf.Frame.ShouldBe(5);
        kf.Value.ShouldBe(1.0); // authored value, not the faded-down sampled value
        e.Document.UndoService.UndoActionName.ShouldBe("Add Keyframe");
    }

    [Fact]
    public async Task RemoveRegistersDeleteKeyframeUndo()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        clip.OpacityTrack = new KeyframeTrack<double>([new Keyframe<double>(10, 0.5)]);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new KeyframesViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        vm.Remove(AnimatableProperty.Opacity, 10);

        e.ClipFor("c1")!.OpacityTrack.ShouldBeNull();
        e.Document.UndoService.UndoActionName.ShouldBe("Delete Keyframe");
    }

    [Fact]
    public async Task SetInterpolationRegistersChangeInterpolationUndo()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        clip.OpacityTrack = new KeyframeTrack<double>([new Keyframe<double>(10, 0.5)]);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new KeyframesViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        vm.SetInterpolation(AnimatableProperty.Opacity, 10, Interpolation.Hold);

        vm.InterpolationAt(AnimatableProperty.Opacity, 10).ShouldBe(Interpolation.Hold);
        e.Document.UndoService.UndoActionName.ShouldBe("Change Interpolation");
    }

    [Fact]
    public async Task ApplyMoveIsLiveAndCommitMoveRegistersOneUndoStepNamedMoveKeyframe()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        clip.OpacityTrack = new KeyframeTrack<double>([new Keyframe<double>(10, 0.5), new Keyframe<double>(40, 1.0)]);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new KeyframesViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));
        var undoDepthBefore = e.Document.UndoService.UndoStackDepth;

        vm.ApplyMove(AnimatableProperty.Opacity, 10, 15);
        vm.ApplyMove(AnimatableProperty.Opacity, 15, 20);
        e.Document.UndoService.CanUndo.ShouldBeFalse(); // live ticks register nothing

        vm.CommitMove();

        e.ClipFor("c1")!.OpacityTrack!.Keyframes.Select(k => k.Frame).ShouldBe([20, 40]);
        e.Document.UndoService.UndoStackDepth.ShouldBe(undoDepthBefore + 1);
        e.Document.UndoService.UndoActionName.ShouldBe("Move Keyframe");
    }

    [Fact]
    public async Task CommitMoveWithNoNetMovementRegistersNoUndo()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        clip.OpacityTrack = new KeyframeTrack<double>([new Keyframe<double>(10, 0.5)]);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new KeyframesViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));
        var undoDepthBefore = e.Document.UndoService.UndoStackDepth;

        vm.ApplyMove(AnimatableProperty.Opacity, 10, 20);
        vm.ApplyMove(AnimatableProperty.Opacity, 20, 10); // dragged back to origin

        vm.CommitMove();

        e.Document.UndoService.UndoStackDepth.ShouldBe(undoDepthBefore);
    }

    [Fact]
    public async Task CancelMoveRevertsToThePreDragState()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        clip.OpacityTrack = new KeyframeTrack<double>([new Keyframe<double>(10, 0.5)]);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new KeyframesViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        vm.ApplyMove(AnimatableProperty.Opacity, 10, 25);
        vm.CancelMove();

        e.ClipFor("c1")!.OpacityTrack!.Keyframes.Select(k => k.Frame).ShouldBe([10]);
        e.Document.UndoService.CanUndo.ShouldBeFalse();
    }
}
