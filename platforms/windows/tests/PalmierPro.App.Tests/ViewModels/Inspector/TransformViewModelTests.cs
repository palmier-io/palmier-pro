using PalmierPro.App.Tests.ViewModels.Editor;
using PalmierPro.App.ViewModels.Inspector;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.Inspector;

/// Covers TransformViewModel — the Video tab's transform/crop/opacity/flip/blend/speed/keyframe
/// surface over TimelineEditorViewModel's ApplyClipProperties/CommitClipProperties/MutateClips/
/// ApplyClipSpeed/CommitClipSpeed primitives. Ports the relevant slice of
/// Tests/PalmierProTests/Timeline/ClipMutationsTests.swift's writePosition/applyClipSpeed suites
/// plus this port's own live-refresh (RefreshParams) and one-undo-per-gesture contracts.
public class TransformViewModelTests
{
    [Fact]
    public async Task ClipsExcludesTextClipsFromTheTransformSelection()
    {
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [
            EditorFixtures.VideoTrack(clips: [
                EditorFixtures.Clip(id: "v", start: 0, duration: 20),
                EditorFixtures.Clip(id: "t", mediaType: ClipType.Text, start: 0, duration: 20),
            ]),
        ]);
        using var _ = temp;
        var v = e.ClipFor("v")!;
        var t = e.ClipFor("t")!;

        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, v, t));

        vm.Clips.Select(c => c.Id).ShouldBe(["v"]);
    }

    [Fact]
    public async Task SharedValuesAreNullWhenTheSelectionDisagrees()
    {
        var a = EditorFixtures.Clip(id: "a", start: 0, duration: 20);
        var b = EditorFixtures.Clip(id: "b", start: 20, duration: 20);
        a.Opacity = 1.0;
        b.Opacity = 0.5;
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [a, b])]);
        using var _ = temp;
        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("a")!, e.ClipFor("b")!));

        vm.OpacityShared.ShouldBeNull();
    }

    [Fact]
    public async Task ApplyPositionWithNoActiveKeyframeTrackWritesTransformCenterDirectly()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        clip.Transform.Width = 0.4;
        clip.Transform.Height = 0.4;
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        vm.ApplyPosition(0.4, 0.4);

        var updated = e.ClipFor("c1")!;
        updated.Transform.CenterX.ShouldBe(0.6, 0.0001); // 0.4 + width/2
        updated.Transform.CenterY.ShouldBe(0.6, 0.0001);
    }

    [Fact]
    public async Task ApplyPositionWithAnActiveKeyframeTrackUpsertsAKeyframeInsteadOfTheFallbackTransform()
    {
        // Regression coverage for the Mac's writePositionWithActiveKeyframesPreservesFallbackTransform
        // bug: writing straight to Transform.CenterX/Y while a position track is active corrupts the
        // fallback the moment keyframes are ever cleared.
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        clip.Transform.CenterX = 0.5;
        clip.Transform.CenterY = 0.5;
        clip.PositionTrack = new KeyframeTrack<AnimPair>([new Keyframe<AnimPair>(0, new AnimPair(0.1, 0.1))]);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        e.CurrentFrame = 0;
        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        vm.ApplyPosition(0.4, 0.4);

        var updated = e.ClipFor("c1")!;
        var kf = updated.PositionTrack!.Keyframes.Single(k => k.Frame == 0);
        kf.Value.A.ShouldBe(0.4);
        kf.Value.B.ShouldBe(0.4);
        updated.Transform.CenterX.ShouldBe(0.5); // fallback untouched
        updated.Transform.CenterY.ShouldBe(0.5);
    }

    [Fact]
    public async Task ApplyPositionIsLiveAndFiresRefreshVisualsWithoutAStructuralRebuild()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));
        var refreshCount = 0;
        var structuralCount = 0;
        e.RefreshVisualsRequested += (_, _) => refreshCount++;
        e.StructuralChangeRequested += (_, _) => structuralCount++;

        vm.ApplyPosition(0.2, 0.3);
        vm.ApplyPosition(0.25, 0.35);

        refreshCount.ShouldBe(2);
        structuralCount.ShouldBe(0);
        e.Document.UndoService.CanUndo.ShouldBeFalse(); // no undo entry until commit
    }

    [Fact]
    public async Task ApplyPositionPushesALiveRefreshParamsPatchToTheEngine()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var engine = new FakeParamCaptureVideoEngine();
        var (e, temp) = await InspectorFixtures.MakeAsync(engine, tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        vm.ApplyPosition(0.2, 0.3);

        engine.Patches.ShouldHaveSingleItem();
        engine.Patches[0].Clips.Single().ClipId.ShouldBe("c1");
    }

    [Fact]
    public async Task CommitPositionRegistersOneUndoStepNamedChangePosition()
    {
        // Mirrors the Mac's EditorViewModel+Keyframes.swift commitPosition -> "Change Position";
        // TimelineEditorViewModel.CommitClipProperties' own default ("Change Clip Property") is
        // overridden by an explicit SetActionName call, same pattern as CommitMoveKeyframe.
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));
        var undoDepthBefore = e.Document.UndoService.UndoStackDepth;

        vm.ApplyPosition(0.2, 0.3);
        vm.ApplyPosition(0.25, 0.35);
        vm.CommitPosition(0.3, 0.4);

        e.Document.UndoService.UndoStackDepth.ShouldBe(undoDepthBefore + 1);
        e.Document.UndoService.UndoActionName.ShouldBe("Change Position");
    }

    [Fact]
    public async Task ApplyScaleRescalesHeightByTheSourceRelativeAspect()
    {
        var clip = EditorFixtures.Clip(id: "c1", mediaRef: "media-1", start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        // Canvas defaults to 1920x1080 (16:9); a 2:1 source is 1.125x "wider" relative to the canvas.
        e.Document.Manifest.Entries.Add(new MediaManifestEntry(
            "media-1", "src.mov", ClipType.Video, MediaSource.External("C:/src.mov"), 10,
            sourceWidth: 1000, sourceHeight: 500));
        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        vm.CommitScale(0.5);

        var updated = e.ClipFor("c1")!;
        updated.Transform.Width.ShouldBe(0.5);
        (updated.Transform.Height * 1.125).ShouldBe(0.5, 0.0001);
        e.Document.UndoService.UndoActionName.ShouldBe("Change Scale");
    }

    [Fact]
    public async Task ApplyRotationWithNoActiveKeyframeTrackWritesTransformRotation()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        vm.CommitRotation(45);

        e.ClipFor("c1")!.Transform.Rotation.ShouldBe(45);
    }

    [Fact]
    public async Task ApplyOpacityWithAnActiveKeyframeTrackUpsertsAKeyframe()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        clip.OpacityTrack = new KeyframeTrack<double>([new Keyframe<double>(0, 1.0)]);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        e.CurrentFrame = 0;
        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        vm.CommitOpacity(0.5);

        var updated = e.ClipFor("c1")!;
        updated.OpacityTrack!.Keyframes.Single(k => k.Frame == 0).Value.ShouldBe(0.5);
        updated.Opacity.ShouldBe(1.0); // fallback untouched
    }

    [Fact]
    public async Task ApplyCropPresetOriginalResetsToIdentityAndRegistersOneUndo()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        clip.Crop = new Crop { Left = 0.1, Top = 0.1, Right = 0, Bottom = 0 };
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));
        var undoDepthBefore = e.Document.UndoService.UndoStackDepth;

        vm.ApplyCropPreset(CropAspectLock.Original);

        var updated = e.ClipFor("c1")!;
        updated.Crop.IsIdentity.ShouldBeTrue();
        e.Document.UndoService.UndoStackDepth.ShouldBe(undoDepthBefore + 1);
        vm.CropAspectLockState.ShouldBe(CropAspectLock.Original);
    }

    [Fact]
    public async Task ApplyCropPresetFreeOnlyRemembersThePickWithoutMutatingTheCrop()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        clip.Crop = new Crop { Left = 0.1, Top = 0, Right = 0, Bottom = 0 };
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        vm.ApplyCropPreset(CropAspectLock.Free);

        e.ClipFor("c1")!.Crop.Left.ShouldBe(0.1);
        vm.CropAspectLockState.ShouldBe(CropAspectLock.Free);
        e.Document.UndoService.CanUndo.ShouldBeFalse();
    }

    [Fact]
    public async Task ApplyCropPresetIsANoOpMutationForAMultiClipSelection()
    {
        var a = EditorFixtures.Clip(id: "a", start: 0, duration: 20);
        var b = EditorFixtures.Clip(id: "b", start: 20, duration: 20);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [a, b])]);
        using var _ = temp;
        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("a")!, e.ClipFor("b")!));

        vm.ApplyCropPreset(CropAspectLock.Original);

        // The pick is still remembered (menu state), but with no single clip to target nothing commits.
        vm.CropAspectLockState.ShouldBe(CropAspectLock.Original);
        e.Document.UndoService.CanUndo.ShouldBeFalse();
    }

    [Fact]
    public async Task ToggleFlipHorizontalFlipsAndRegistersOneUndoNamedFlipHorizontal()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));
        var undoDepthBefore = e.Document.UndoService.UndoStackDepth;

        vm.ToggleFlipHorizontal();

        e.ClipFor("c1")!.Transform.FlipHorizontal.ShouldBeTrue();
        e.Document.UndoService.UndoStackDepth.ShouldBe(undoDepthBefore + 1);
        e.Document.UndoService.UndoActionName.ShouldBe("Flip Horizontal");

        vm.ToggleFlipHorizontal();

        e.ClipFor("c1")!.Transform.FlipHorizontal.ShouldBeFalse();
        e.Document.UndoService.UndoStackDepth.ShouldBe(undoDepthBefore + 2);
    }

    [Fact]
    public async Task ToggleFlipVerticalRegistersOneUndoNamedFlipVertical()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        vm.ToggleFlipVertical();

        e.ClipFor("c1")!.Transform.FlipVertical.ShouldBeTrue();
        e.Document.UndoService.UndoActionName.ShouldBe("Flip Vertical");
    }

    [Fact]
    public async Task SetBlendModeNormalClearsToNullAndRegistersOneUndoNamedBlendMode()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        clip.BlendMode = BlendMode.Multiply;
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        vm.SetBlendMode(BlendMode.Normal);

        e.ClipFor("c1")!.BlendMode.ShouldBeNull();
        e.Document.UndoService.UndoActionName.ShouldBe("Blend Mode");
    }

    [Fact]
    public async Task ResetTransformClearsTracksFadesAndOpacityInOneUndoStep()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        clip.Opacity = 0.4;
        clip.FadeInFrames = 10;
        clip.FadeOutFrames = 10;
        clip.OpacityTrack = new KeyframeTrack<double>([new Keyframe<double>(0, 0.4)]);
        clip.RotationTrack = new KeyframeTrack<double>([new Keyframe<double>(0, 30)]);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));
        var undoDepthBefore = e.Document.UndoService.UndoStackDepth;

        vm.ResetTransform();

        var updated = e.ClipFor("c1")!;
        updated.Opacity.ShouldBe(1.0);
        updated.FadeInFrames.ShouldBe(0);
        updated.FadeOutFrames.ShouldBe(0);
        updated.OpacityTrack.ShouldBeNull();
        updated.RotationTrack.ShouldBeNull();
        e.Document.UndoService.UndoStackDepth.ShouldBe(undoDepthBefore + 1);
        e.Document.UndoService.UndoActionName.ShouldBe("Reset Transform");
    }

    [Fact]
    public async Task SpeedClipsIncludesRetimeableClipsOnlyExcludingTextAndSequence()
    {
        var v = EditorFixtures.Clip(id: "v", start: 0, duration: 60);
        var t = EditorFixtures.Clip(id: "t", mediaType: ClipType.Text, start: 0, duration: 60);
        var s = EditorFixtures.Clip(id: "s", mediaType: ClipType.Sequence, start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [v, t, s])]);
        using var _ = temp;
        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("v")!, e.ClipFor("t")!, e.ClipFor("s")!));

        vm.SpeedClips.Select(c => c.Id).ShouldBe(["v"]);
    }

    [Fact]
    public async Task CommitSpeedAppliesOnlyToEligibleClipsAndRegistersOneUndoNamedChangeSpeed()
    {
        var v = EditorFixtures.Clip(id: "v", start: 0, duration: 60);
        var t = EditorFixtures.Clip(id: "t", mediaType: ClipType.Text, start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [v, t])]);
        using var _ = temp;
        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("v")!, e.ClipFor("t")!));
        var undoDepthBefore = e.Document.UndoService.UndoStackDepth;

        vm.ApplySpeed(2.0);
        vm.CommitSpeed(2.0);

        e.ClipFor("v")!.DurationFrames.ShouldBe(30);
        e.ClipFor("t")!.DurationFrames.ShouldBe(60); // text is never retimeable — untouched
        e.Document.UndoService.UndoStackDepth.ShouldBe(undoDepthBefore + 1);
        e.Document.UndoService.UndoActionName.ShouldBe("Change Speed");
    }

    [Fact]
    public async Task KeyframeHelpersReadPreviousAndNextFramesFromTheClipsTrack()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        clip.OpacityTrack = new KeyframeTrack<double>([
            new Keyframe<double>(0, 1.0),
            new Keyframe<double>(20, 0.5),
            new Keyframe<double>(40, 0.0),
        ]);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        vm.HasKeyframe("c1", AnimatableProperty.Opacity, 20).ShouldBeTrue();
        vm.PreviousKeyframeFrame("c1", AnimatableProperty.Opacity, 30).ShouldBe(20);
        vm.NextKeyframeFrame("c1", AnimatableProperty.Opacity, 30).ShouldBe(40);
        vm.NextKeyframeFrame("c1", AnimatableProperty.Opacity, 40).ShouldBeNull();
    }

    [Fact]
    public async Task StampKeyframeAndRemoveKeyframeUseTheirOwnDedicatedActionNames()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        e.CurrentFrame = 5;
        var vm = new TransformViewModel(InspectorFixtures.ContextFor(e, e.ClipFor("c1")!));

        vm.StampKeyframe("c1", AnimatableProperty.Opacity);

        e.ClipFor("c1")!.OpacityTrack!.Keyframes.Single().Frame.ShouldBe(5);
        e.Document.UndoService.UndoActionName.ShouldBe("Add Keyframe");

        vm.RemoveKeyframe("c1", AnimatableProperty.Opacity, 5);

        e.ClipFor("c1")!.OpacityTrack.ShouldBeNull();
        e.Document.UndoService.UndoActionName.ShouldBe("Delete Keyframe");
    }
}
