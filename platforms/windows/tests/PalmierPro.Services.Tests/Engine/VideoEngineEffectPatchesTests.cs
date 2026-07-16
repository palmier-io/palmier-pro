using PalmierPro.Core.Models;
using PalmierPro.Services.Engine;
using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests.Engine;

/// Covers <see cref="VideoEngine.ApplyEffectPatches"/> directly — the RefreshParams patch-merge
/// step is pure C# (no native session needed), so this exercises it without the heavier
/// native-engine round trip RefreshParamsTests (PalmierPro.Rendering.Tests) uses.
///
/// Regression: a patch whose EffectType matched none of the clip's EXISTING SnapshotEffects used
/// to be silently dropped — the common first-grade case (dragging a color wheel on a clip with no
/// color.wheels effect yet) froze the live preview for the whole drag. ApplyEffectPatches must now
/// synthesize the missing effect from its registry descriptor (defaults for every un-patched key)
/// and insert it in canonical order, mirroring what a real "Add Effect" would produce.
public sealed class VideoEngineEffectPatchesTests
{
    private static SnapshotEffect Existing(string type, params (string Key, double Value)[] @params) =>
        new(type, true, @params.ToDictionary(p => p.Key, p => new EffectParam(p.Value)));

    [Fact]
    public void PatchForAnAbsentEffectTypeSynthesizesItWithRegistryDefaults()
    {
        var effects = new List<SnapshotEffect> { Existing("color.exposure", ("ev", 0.5)) };
        var patches = new List<EffectParamPatch> { new("color.wheels", "lift_x", 0.25) };

        var result = VideoEngine.ApplyEffectPatches(effects, patches);

        result.Count.ShouldBe(2);
        var wheels = result.Single(e => e.Type == "color.wheels");
        wheels.Enabled.ShouldBeTrue();
        wheels.Params["lift_x"].Value.ShouldBe(0.25);
        // Every other color.wheels key falls back to its EffectRegistry descriptor default —
        // native's ResolveParam would otherwise supply these, but the live-refresh path never
        // reaches native for a brand-new effect until this synthesis exists.
        wheels.Params["gamma_m"].Value.ShouldBe(1.0);
        wheels.Params["gain_m"].Value.ShouldBe(1.0);
        wheels.Params["lift_y"].Value.ShouldBe(0.0);

        // The pre-existing effect is untouched.
        result.Single(e => e.Type == "color.exposure").Params["ev"].Value.ShouldBe(0.5);
    }

    [Fact]
    public void SynthesizedEffectIsInsertedInCanonicalOrderNotAppended()
    {
        // color.wheels ranks between color.exposure and blur.gaussian in EffectRegistry.CanonicalOrder.
        var effects = new List<SnapshotEffect>
        {
            Existing("color.exposure", ("ev", 0)),
            Existing("blur.gaussian", ("radius", 8)),
        };
        var patches = new List<EffectParamPatch> { new("color.wheels", "gain_m", 1.2) };

        var result = VideoEngine.ApplyEffectPatches(effects, patches);

        result.Select(e => e.Type).ShouldBe(["color.exposure", "color.wheels", "blur.gaussian"]);
    }

    [Fact]
    public void MultiplePatchesForTheSameAbsentEffectAllLandOnTheOneSynthesizedInstance()
    {
        var effects = new List<SnapshotEffect>();
        var patches = new List<EffectParamPatch>
        {
            new("color.wheels", "lift_x", 0.1),
            new("color.wheels", "gamma_m", 1.5),
        };

        var result = VideoEngine.ApplyEffectPatches(effects, patches);

        result.Count.ShouldBe(1);
        result[0].Params["lift_x"].Value.ShouldBe(0.1);
        result[0].Params["gamma_m"].Value.ShouldBe(1.5);
    }

    [Fact]
    public void PatchForAnEffectTypeThatAlreadyExistsNeverDuplicatesIt()
    {
        var effects = new List<SnapshotEffect> { Existing("color.wheels", ("lift_x", 0), ("gamma_m", 1)) };
        var patches = new List<EffectParamPatch> { new("color.wheels", "lift_x", 0.4) };

        var result = VideoEngine.ApplyEffectPatches(effects, patches);

        result.Count.ShouldBe(1);
        result[0].Params["lift_x"].Value.ShouldBe(0.4);
    }

    [Fact]
    public void PatchForAnUnregisteredEffectTypeIsSilentlyIgnoredNotThrown()
    {
        var effects = new List<SnapshotEffect> { Existing("color.exposure", ("ev", 0)) };
        var patches = new List<EffectParamPatch> { new("future.hologram", "amount", 1) };

        var result = VideoEngine.ApplyEffectPatches(effects, patches);

        result.Count.ShouldBe(1);
        result[0].Type.ShouldBe("color.exposure");
    }
}
