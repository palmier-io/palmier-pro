using PalmierPro.App.Tests.ViewModels.Editor;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.App.ViewModels.Inspector;
using PalmierPro.App.Views.Inspector;
using PalmierPro.Core.Effects;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.Inspector;

/// Covers EffectsViewModel's add/remove/toggle/reorder/param-edit/keyframe-toggle surface — the
/// M5 Effects tab's per-clip effect stack over EffectRegistry's catalog.
public class EffectsViewModelTests
{
    private static InspectorTabContext ContextFor(TimelineEditorViewModel vm, params Clip[] clips) => new()
    {
        SelectionState = clips.Length == 1 ? InspectorSelectionState.Single : InspectorSelectionState.Multi,
        SelectedClips = clips,
        Timeline = vm,
    };

    [Fact]
    public async Task NewSelectionStartsWithAnEmptyStack()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "a", start: 0, duration: 20)]),
        ]);
        using var _ = temp;
        var clip = e.ClipFor("a")!;

        var vm = new EffectsViewModel(ContextFor(e, clip));

        vm.Stack.ShouldBeEmpty();
        vm.Catalog.Sum(g => g.Effects.Count).ShouldBe(20);
    }

    [Fact]
    public async Task AddEffectInsertsItIntoTheClipsEffectsAndTheStack()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "a", start: 0, duration: 20)]),
        ]);
        using var _ = temp;
        var clip = e.ClipFor("a")!;
        var vm = new EffectsViewModel(ContextFor(e, clip));
        var descriptor = EffectRegistry.Descriptor("stylize.vignette")!;

        vm.AddEffect(descriptor);

        vm.Stack.Count.ShouldBe(1);
        vm.Stack[0].EffectId.ShouldBe("stylize.vignette");
        vm.Stack[0].Enabled.ShouldBeTrue();
        vm.IsInStack("stylize.vignette").ShouldBeTrue();
        clip.Effects!.Single().Type.ShouldBe("stylize.vignette");
        e.Document.UndoService.CanUndo.ShouldBeTrue();
    }

    [Fact]
    public async Task AddingTheSameEffectTwiceIsANoOp()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "a", start: 0, duration: 20)]),
        ]);
        using var _ = temp;
        var clip = e.ClipFor("a")!;
        var vm = new EffectsViewModel(ContextFor(e, clip));
        var descriptor = EffectRegistry.Descriptor("blur.gaussian")!;
        vm.AddEffect(descriptor);

        vm.AddEffect(descriptor);

        clip.Effects!.Count.ShouldBe(1);
    }

    [Fact]
    public async Task RemoveEffectDropsItFromTheClipAndClearsAnEmptyList()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "a", start: 0, duration: 20)]),
        ]);
        using var _ = temp;
        var clip = e.ClipFor("a")!;
        var vm = new EffectsViewModel(ContextFor(e, clip));
        vm.AddEffect(EffectRegistry.Descriptor("blur.gaussian")!);

        vm.RemoveEffect("blur.gaussian");

        vm.Stack.ShouldBeEmpty();
        clip.Effects.ShouldBeNull();
    }

    [Fact]
    public async Task ToggleEnabledFlipsTheEffectsEnabledFlag()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "a", start: 0, duration: 20)]),
        ]);
        using var _ = temp;
        var clip = e.ClipFor("a")!;
        var vm = new EffectsViewModel(ContextFor(e, clip));
        vm.AddEffect(EffectRegistry.Descriptor("blur.gaussian")!);

        vm.ToggleEnabled("blur.gaussian");

        clip.Effects!.Single().Enabled.ShouldBeFalse();
        vm.Stack[0].Enabled.ShouldBeFalse();

        vm.ToggleEnabled("blur.gaussian");

        clip.Effects!.Single().Enabled.ShouldBeTrue();
    }

    [Fact]
    public async Task MoveEffectSwapsAdjacentStackOrder()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "a", start: 0, duration: 20)]),
        ]);
        using var _ = temp;
        var clip = e.ClipFor("a")!;
        var vm = new EffectsViewModel(ContextFor(e, clip));
        vm.AddEffect(EffectRegistry.Descriptor("blur.gaussian")!);
        vm.AddEffect(EffectRegistry.Descriptor("stylize.grain")!);
        vm.Stack.Select(s => s.EffectId).ShouldBe(["blur.gaussian", "stylize.grain"]);

        vm.MoveEffect("stylize.grain", -1);

        vm.Stack.Select(s => s.EffectId).ShouldBe(["stylize.grain", "blur.gaussian"]);
        clip.Effects!.Select(x => x.Type).ShouldBe(["stylize.grain", "blur.gaussian"]);
    }

    [Fact]
    public async Task MoveEffectPastAnEdgeIsANoOp()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "a", start: 0, duration: 20)]),
        ]);
        using var _ = temp;
        var clip = e.ClipFor("a")!;
        var vm = new EffectsViewModel(ContextFor(e, clip));
        vm.AddEffect(EffectRegistry.Descriptor("blur.gaussian")!);

        vm.MoveEffect("blur.gaussian", -1);
        vm.MoveEffect("blur.gaussian", 1);

        vm.Stack.Select(s => s.EffectId).ShouldBe(["blur.gaussian"]);
    }

    [Fact]
    public async Task CommitParamValueUpdatesTheParamAndRegistersOneUndoEntry()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "a", start: 0, duration: 20)]),
        ]);
        using var _ = temp;
        var clip = e.ClipFor("a")!;
        var vm = new EffectsViewModel(ContextFor(e, clip));
        vm.AddEffect(EffectRegistry.Descriptor("blur.gaussian")!);
        var undoDepthBefore = e.Document.UndoService.UndoStackDepth;

        vm.ApplyParamValue("blur.gaussian", "radius", 40);
        vm.ApplyParamValue("blur.gaussian", "radius", 55);
        vm.CommitParamValue("blur.gaussian", "radius", 60);

        clip.Effects!.Single(x => x.Type == "blur.gaussian").Params["radius"].Value.ShouldBe(60);
        vm.Stack[0].Params.Single(p => p.Spec.Key == "radius").Value.ShouldBe(60);
        e.Document.UndoService.UndoStackDepth.ShouldBe(undoDepthBefore + 1); // one entry for the whole drag, not per ApplyParamValue call
    }

    [Fact]
    public async Task CommittingBackToTheOriginalValueRegistersNoUndo()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "a", start: 0, duration: 20)]),
        ]);
        using var _ = temp;
        var clip = e.ClipFor("a")!;
        var vm = new EffectsViewModel(ContextFor(e, clip));
        vm.AddEffect(EffectRegistry.Descriptor("blur.gaussian")!);
        var originalValue = clip.Effects!.Single().Params["radius"].Value;
        var undoDepthBefore = e.Document.UndoService.UndoStackDepth;

        vm.ApplyParamValue("blur.gaussian", "radius", 90);
        vm.CommitParamValue("blur.gaussian", "radius", originalValue!.Value);

        e.Document.UndoService.UndoStackDepth.ShouldBe(undoDepthBefore);
    }

    [Fact]
    public async Task ToggleKeyframeStampsThenRemovesAKeyframeAtThePlayhead()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "a", start: 0, duration: 20)]),
        ]);
        using var _ = temp;
        var clip = e.ClipFor("a")!;
        var vm = new EffectsViewModel(ContextFor(e, clip));
        vm.AddEffect(EffectRegistry.Descriptor("blur.gaussian")!);
        e.SeekToFrame(5);

        vm.ToggleKeyframe("blur.gaussian", "radius");

        var track = clip.Effects!.Single().Params["radius"].Track;
        track.ShouldNotBeNull();
        track.Keyframes.Single().Frame.ShouldBe(5);

        vm.ToggleKeyframe("blur.gaussian", "radius");

        clip.Effects!.Single().Params["radius"].Track.ShouldBeNull();
    }

    [Fact]
    public async Task ApplyingAParamWithThePlayheadOutsideTheClipUpdatesTheActiveKeyframeInsteadOfDestroyingTheTrack()
    {
        // Regression: SetParamValue used to gate the keyframe-track upsert on the playhead sitting
        // inside the clip's [start,end) range. With a single clip selected and its param already
        // animated, moving the playhead off the clip and nudging the slider fell into the `else`
        // branch and replaced the whole EffectParam — silently wiping every keyframe on the track.
        // A second, unselected clip out at [40,60) extends the timeline to 60 frames so the playhead
        // can actually reach frame 45 — SeekToFrame clamps to Timeline.TotalFrames, so with clip "a"
        // alone the playhead would pin at 20 and never leave the clip's own [0,20) span.
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [
                EditorFixtures.Clip(id: "a", start: 0, duration: 20),
                EditorFixtures.Clip(id: "b", start: 40, duration: 20),
            ]),
        ]);
        using var _ = temp;
        var clip = e.ClipFor("a")!;
        var vm = new EffectsViewModel(ContextFor(e, clip));
        vm.AddEffect(EffectRegistry.Descriptor("blur.gaussian")!);
        e.SeekToFrame(5);
        vm.ToggleKeyframe("blur.gaussian", "radius"); // stamps a keyframe at frame 5 (offset 5)

        e.SeekToFrame(45); // playhead now outside clip "a"'s [0,20) range, clip "a" stays selected
        vm.ApplyParamValue("blur.gaussian", "radius", 77);

        var track = clip.Effects!.Single().Params["radius"].Track;
        track.ShouldNotBeNull();
        track.Keyframes.Count.ShouldBe(2); // the original keyframe at 5 plus a new one at offset 45
        track.Keyframes.ShouldContain(k => k.Frame == 5);
        track.Keyframes.Single(k => k.Frame == 45).Value.ShouldBe(77);
    }

    [Fact]
    public async Task ToggleKeyframeIsANoOpForAMultiClipSelection()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [
                EditorFixtures.Clip(id: "a", start: 0, duration: 20),
                EditorFixtures.Clip(id: "b", start: 20, duration: 20),
            ]),
        ]);
        using var _ = temp;
        var a = e.ClipFor("a")!;
        var b = e.ClipFor("b")!;
        var vm = new EffectsViewModel(ContextFor(e, a, b));
        vm.AddEffect(EffectRegistry.Descriptor("blur.gaussian")!);

        vm.ToggleKeyframe("blur.gaussian", "radius");

        a.Effects!.Single().Params["radius"].Track.ShouldBeNull();
    }

    [Fact]
    public async Task AddEffectAppliesToEveryClipInAMultiClipSelection()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [
                EditorFixtures.Clip(id: "a", start: 0, duration: 20),
                EditorFixtures.Clip(id: "b", start: 20, duration: 20),
            ]),
        ]);
        using var _ = temp;
        var a = e.ClipFor("a")!;
        var b = e.ClipFor("b")!;
        var vm = new EffectsViewModel(ContextFor(e, a, b));

        vm.AddEffect(EffectRegistry.Descriptor("stylize.grain")!);

        a.Effects!.Single().Type.ShouldBe("stylize.grain");
        b.Effects!.Single().Type.ShouldBe("stylize.grain");
    }

    [Fact]
    public async Task StackIgnoresUnregisteredLegacyEffectTypes()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "a", start: 0, duration: 20)]),
        ]);
        using var _ = temp;
        var clip = e.ClipFor("a")!;
        clip.Effects = [Effect.Make("future.hologram")];

        var vm = new EffectsViewModel(ContextFor(e, clip));

        vm.Stack.ShouldBeEmpty();
    }

    [Fact]
    public async Task DetachStopsReactingToFurtherTimelineChanges()
    {
        var (e, temp) = await EditorFixtures.MakeAsync([
            EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(id: "a", start: 0, duration: 20)]),
        ]);
        using var _ = temp;
        var clip = e.ClipFor("a")!;
        var vm = new EffectsViewModel(ContextFor(e, clip));
        var stackBeforeDetach = vm.Stack;

        vm.Detach();
        // A structural change made through a path this VM didn't initiate (so only the
        // StructuralChangeRequested subscription Detach removed could have refreshed it) must
        // leave Stack exactly as this VM last computed it — mirrors EffectsTabView's Unloaded
        // handler, which calls Detach right before the view (and this VM) is discarded.
        clip.Effects = [EffectRegistry.Descriptor("stylize.grain")!.MakeEffect()];
        e.NotifyTimelineChanged();

        vm.Stack.ShouldBeSameAs(stackBeforeDetach);
    }
}
