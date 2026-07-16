using PalmierPro.App.Tests.ViewModels.Editor;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.App.ViewModels.Inspector;
using PalmierPro.App.Views.Inspector;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.Inspector;

/// Covers ColorViewModel — the Color tab's Lift/Gamma/Gain wheels, master grade curve, and hue
/// curves over the "color.wheels"/"color.curves"/"color.hueCurves" effect singletons. Ports the
/// apply/commit contract Inspector/Tabs/AdjustTab.swift's wheelsContent/curvesContent/
/// hueCurvesContent describe: a live Apply mutates the model directly with undo suppressed (wheels
/// additionally push a RefreshParams preview), a Commit registers exactly one undo step for the
/// whole gesture, and an identity-valued adjustment prunes its effect entirely rather than
/// persisting a no-op.
public class ColorViewModelTests
{
    private static InspectorTabContext ContextFor(TimelineEditorViewModel vm, params Clip[] clips) =>
        InspectorFixtures.ContextFor(vm, clips);

    [Fact]
    public async Task ReadWheelReturnsSpecDefaultsWhenNoWheelsEffectExists()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new ColorViewModel(ContextFor(e, e.ClipFor("c1")!));

        var lift = vm.ReadWheel("lift");
        lift.X.ShouldBe(0);
        lift.Y.ShouldBe(0);
        lift.Master.ShouldBe(0);
        lift.MasterMin.ShouldBe(-0.5);
        lift.MasterMax.ShouldBe(0.5);

        var gamma = vm.ReadWheel("gamma");
        gamma.Master.ShouldBe(1.0);
        gamma.MasterMin.ShouldBe(0.5);
        gamma.MasterMax.ShouldBe(2.0);
    }

    [Fact]
    public async Task ApplyWheelColorPushesALiveRefreshParamsPatchWithoutMutatingTheModel()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var engine = new FakeParamCaptureVideoEngine();
        var (e, temp) = await InspectorFixtures.MakeAsync(engine, tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new ColorViewModel(ContextFor(e, e.ClipFor("c1")!));

        vm.ApplyWheelColor("lift", 0.2, -0.1);

        engine.Patches.ShouldHaveSingleItem();
        engine.Patches[0].Clips.Single().Effects!.ShouldContain(p => p.EffectType == "color.wheels" && p.ParamKey == "lift_x" && p.Value == 0.2);
        e.ClipFor("c1")!.Effects.ShouldBeNull(); // live path never touches the model
        e.Document.UndoService.CanUndo.ShouldBeFalse();
    }

    [Fact]
    public async Task CommitWheelColorWritesTheWheelsEffectAndRegistersOneUndoNamedAfterThePrefix()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new ColorViewModel(ContextFor(e, e.ClipFor("c1")!));
        var undoDepthBefore = e.Document.UndoService.UndoStackDepth;

        vm.CommitWheelColor("lift", 0.2, -0.1);

        var effect = e.ClipFor("c1")!.Effects!.Single(x => x.Type == "color.wheels");
        effect.Params["lift_x"].Value.ShouldBe(0.2);
        effect.Params["lift_y"].Value.ShouldBe(-0.1);
        e.Document.UndoService.UndoStackDepth.ShouldBe(undoDepthBefore + 1);
        e.Document.UndoService.UndoActionName.ShouldBe("Adjust Lift");
        vm.HasWheelAdjustment.ShouldBeTrue();
    }

    [Fact]
    public async Task CommittingBackToDefaultValuesPrunesTheWheelsEffect()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new ColorViewModel(ContextFor(e, e.ClipFor("c1")!));
        vm.CommitWheelColor("lift", 0.2, -0.1);
        var undoDepthAfterFirstCommit = e.Document.UndoService.UndoStackDepth;

        vm.CommitWheelColor("lift", 0, 0);

        e.ClipFor("c1")!.Effects.ShouldBeNull();
        vm.HasWheelAdjustment.ShouldBeFalse();
        e.Document.UndoService.UndoStackDepth.ShouldBe(undoDepthAfterFirstCommit + 1);
    }

    [Fact]
    public async Task ResetWheelsIsANoOpWithNoAdjustmentAndRemovesOneWithOneUndoStep()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new ColorViewModel(ContextFor(e, e.ClipFor("c1")!));

        vm.ResetWheels();
        e.Document.UndoService.CanUndo.ShouldBeFalse();

        vm.CommitWheelMaster("gain", 1.3);
        var undoDepthBefore = e.Document.UndoService.UndoStackDepth;

        vm.ResetWheels();

        e.ClipFor("c1")!.Effects.ShouldBeNull();
        e.Document.UndoService.UndoStackDepth.ShouldBe(undoDepthBefore + 1);
        e.Document.UndoService.UndoActionName.ShouldBe("Reset Color Wheels");
    }

    [Fact]
    public async Task CommitWheelColorAppliesToEveryClipInAMultiClipSelection()
    {
        var a = EditorFixtures.Clip(id: "a", start: 0, duration: 20);
        var b = EditorFixtures.Clip(id: "b", start: 20, duration: 20);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [a, b])]);
        using var _ = temp;
        var vm = new ColorViewModel(ContextFor(e, e.ClipFor("a")!, e.ClipFor("b")!));

        vm.CommitWheelColor("gain", 0.1, 0.1);

        e.ClipFor("a")!.Effects!.Single().Params["gain_x"].Value.ShouldBe(0.1);
        e.ClipFor("b")!.Effects!.Single().Params["gain_x"].Value.ShouldBe(0.1);
    }

    [Fact]
    public async Task ReadGradeCurveDefaultsToEmptyForNoCurvesEffect()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new ColorViewModel(ContextFor(e, e.ClipFor("c1")!));

        vm.ReadGradeCurve().Master.ShouldBeEmpty();
        vm.HasCurveAdjustment.ShouldBeFalse();
    }

    [Fact]
    public async Task ApplyCurveChannelMutatesTheModelLiveWithoutRegisteringUndo()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new ColorViewModel(ContextFor(e, e.ClipFor("c1")!));

        vm.ApplyCurveChannel(ColorCurveChannel.Master, [new CurvePoint(0, 0), new CurvePoint(0.5, 0.7), new CurvePoint(1, 1)]);

        vm.ReadGradeCurve().Master.Select(p => p.Y).ShouldContain(0.7);
        e.Document.UndoService.CanUndo.ShouldBeFalse();
    }

    [Fact]
    public async Task CommitCurveChannelWritesTheCurveAndRegistersEditCurvesUndo()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new ColorViewModel(ContextFor(e, e.ClipFor("c1")!));
        var undoDepthBefore = e.Document.UndoService.UndoStackDepth;

        vm.CommitCurveChannel(ColorCurveChannel.Master, [new CurvePoint(0, 0), new CurvePoint(0.5, 0.7), new CurvePoint(1, 1)]);

        vm.HasCurveAdjustment.ShouldBeTrue();
        e.Document.UndoService.UndoStackDepth.ShouldBe(undoDepthBefore + 1);
        e.Document.UndoService.UndoActionName.ShouldBe("Edit Curves");
    }

    [Fact]
    public async Task CommitCurveChannelWithIdentityPointsRemovesTheEffect()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new ColorViewModel(ContextFor(e, e.ClipFor("c1")!));
        vm.CommitCurveChannel(ColorCurveChannel.Master, [new CurvePoint(0, 0), new CurvePoint(0.5, 0.7), new CurvePoint(1, 1)]);

        vm.CommitCurveChannel(ColorCurveChannel.Master, [new CurvePoint(0, 0), new CurvePoint(1, 1)]);

        e.ClipFor("c1")!.Effects.ShouldBeNull();
        vm.HasCurveAdjustment.ShouldBeFalse();
    }

    [Fact]
    public async Task CommitHueCurveChannelWritesTheCurvesAndRegistersEditHueCurvesUndo()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new ColorViewModel(ContextFor(e, e.ClipFor("c1")!));
        var undoDepthBefore = e.Document.UndoService.UndoStackDepth;

        vm.CommitHueCurveChannel(HueCurvesChannel.Sat, [new CurvePoint(0, 0.8), new CurvePoint(1, 0.8)]);

        vm.ReadHueCurves().HueVsSat.Select(p => p.Y).ShouldAllBe(y => y == 0.8);
        vm.HasHueCurveAdjustment.ShouldBeTrue();
        e.Document.UndoService.UndoStackDepth.ShouldBe(undoDepthBefore + 1);
        e.Document.UndoService.UndoActionName.ShouldBe("Edit Hue Curves");
    }

    [Fact]
    public async Task ResetCurvesAndResetHueCurvesUseTheirOwnDedicatedActionNames()
    {
        var clip = EditorFixtures.Clip(id: "c1", start: 0, duration: 60);
        var (e, temp) = await InspectorFixtures.MakeAsync(tracks: [EditorFixtures.VideoTrack(clips: [clip])]);
        using var _ = temp;
        var vm = new ColorViewModel(ContextFor(e, e.ClipFor("c1")!));
        vm.CommitCurveChannel(ColorCurveChannel.Master, [new CurvePoint(0, 0.1), new CurvePoint(1, 1)]);
        vm.CommitHueCurveChannel(HueCurvesChannel.Hue, [new CurvePoint(0, 0.9), new CurvePoint(1, 0.9)]);

        vm.ResetCurves();
        e.Document.UndoService.UndoActionName.ShouldBe("Reset Curves");
        vm.HasCurveAdjustment.ShouldBeFalse();

        vm.ResetHueCurves();
        e.Document.UndoService.UndoActionName.ShouldBe("Reset Hue Curves");
        vm.HasHueCurveAdjustment.ShouldBeFalse();
    }
}
