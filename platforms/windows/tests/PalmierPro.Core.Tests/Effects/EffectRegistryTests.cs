using PalmierPro.Core.Effects;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests.Effects;

/// Keeps three independent tables in sync: Sources/PalmierPro/Compositing/EffectRegistry.swift
/// (the Mac source of truth), platforms/windows/src/PalmierPro.Rendering/native/EffectRegistry.cpp
/// (the native subset — only the 11 custom Metal-kernel effects; see that file's own header
/// comment for why the other 9 CIFilter-only entries aren't there), and this project's
/// PalmierPro.Core/Effects/EffectRegistry.cs (the full 20-entry C# mirror the Inspector's Effects
/// tab reads). <see cref="NativeKernelTable"/> below is a literal transcription of
/// native/EffectRegistry.cpp's `AllDescriptors()` (id/param key/default/min/max) — if that file
/// changes, this table (and the C# registry it's checked against) must change with it.
public class EffectRegistryTests
{
    private readonly record struct NativeParam(string Key, double DefaultValue, double Min, double Max);

    private readonly record struct NativeEntry(string Id, NativeParam[] Params);

    /// Transcribed from native/EffectRegistry.cpp lines 12-82.
    private static readonly NativeEntry[] NativeKernelTable =
    [
        new("color.highlightsShadows", [new("highlights", 0.0, -1.0, 1.0), new("shadows", 0.0, -1.0, 1.0)]),
        new("color.blacksWhites", [new("blacks", 0.0, -1.0, 1.0), new("whites", 0.0, -1.0, 1.0)]),
        new("color.wheels",
        [
            new("lift_x", 0.0, -1.0, 1.0), new("lift_y", 0.0, -1.0, 1.0), new("lift_m", 0.0, -0.5, 0.5),
            new("gamma_x", 0.0, -1.0, 1.0), new("gamma_y", 0.0, -1.0, 1.0), new("gamma_m", 1.0, 0.5, 2.0),
            new("gain_x", 0.0, -1.0, 1.0), new("gain_y", 0.0, -1.0, 1.0), new("gain_m", 1.0, 0.5, 1.5),
        ]),
        new("color.hueCurves", []),
        new("color.lut", [new("intensity", 1.0, 0.0, 1.0)]),
        new("color.curves", []),
        new("detail.clarity", [new("clarity", 0.0, -1.0, 1.0), new("dehaze", 0.0, -1.0, 1.0)]),
        new("key.chroma",
        [
            new("keyHue", 0.333, 0.0, 1.0), new("tolerance", 0.0, 0.0, 1.0),
            new("softness", 0.1, 0.0, 1.0), new("spill", 0.5, 0.0, 1.0),
        ]),
        new("stylize.grain", [new("amount", 0.0, 0.0, 1.0), new("size", 1.5, 0.5, 4.0)]),
        new("stylize.vignette",
        [
            new("amount", 0.0, -1.0, 1.0), new("midpoint", 0.5, 0.0, 1.0),
            new("roundness", 0.0, -1.0, 1.0), new("feather", 0.5, 0.0, 1.0),
        ]),
        new("stylize.glow",
        [
            new("intensity", 0.0, 0.0, 1.0), new("radius", 20.0, 0.0, 100.0),
            new("threshold", 0.6, 0.0, 1.0), new("warmth", 0.0, 0.0, 1.0),
        ]),
    ];

    [Fact]
    public void NativeKernelTableHasElevenEntries() => NativeKernelTable.Length.ShouldBe(11);

    [Theory]
    [MemberData(nameof(NativeEntryIds))]
    public void EveryNativeKernelEffectExistsInTheCSharpRegistryWithMatchingParams(string id)
    {
        var native = NativeKernelTable.Single(n => n.Id == id);
        var descriptor = EffectRegistry.Descriptor(id);

        descriptor.ShouldNotBeNull($"native/EffectRegistry.cpp registers \"{id}\" but the C# EffectRegistry mirror doesn't.");
        descriptor.Params.Count.ShouldBe(native.Params.Length, $"param count mismatch for \"{id}\".");

        foreach (var nativeParam in native.Params)
        {
            var spec = descriptor.Params.SingleOrDefault(p => p.Key == nativeParam.Key);
            spec.ShouldNotBeNull($"\"{id}\" is missing native param \"{nativeParam.Key}\".");
            spec.DefaultValue.ShouldBe(nativeParam.DefaultValue, $"\"{id}.{nativeParam.Key}\" default mismatch.");
            spec.RangeMin.ShouldBe(nativeParam.Min, $"\"{id}.{nativeParam.Key}\" range min mismatch.");
            spec.RangeMax.ShouldBe(nativeParam.Max, $"\"{id}.{nativeParam.Key}\" range max mismatch.");
        }
    }

    public static IEnumerable<object[]> NativeEntryIds() => NativeKernelTable.Select(n => new object[] { n.Id });

    [Fact]
    public void RegistryPortsAllTwentySwiftEntries()
    {
        // Sources/PalmierPro/Compositing/EffectRegistry.swift's `all` = color(7) + wheels(1) +
        // hueCurves(1) + lut(1) + curves(1) + detail(1) + blur(4) + stylize(3) + key(1) = 20.
        EffectRegistry.All.Count.ShouldBe(20);
        EffectRegistry.ById.Count.ShouldBe(20);
    }

    [Fact]
    public void EveryIdIsUnique() =>
        EffectRegistry.All.Select(d => d.Id).Distinct().Count().ShouldBe(EffectRegistry.All.Count);

    [Fact]
    public void CategoriesMatchTheSwiftGrouping()
    {
        EffectRegistry.ByCategory.Select(g => g.Category).ShouldBe(["Color", "Detail", "Blur & Sharpen", "Stylize", "Key"]);
        EffectRegistry.ByCategory.Sum(g => g.Effects.Count).ShouldBe(20);
    }

    [Fact]
    public void LutDescriptorCarriesTheFileResourceKey()
    {
        var lut = EffectRegistry.Descriptor("color.lut");
        lut.ShouldNotBeNull();
        lut.ResourceKey.ShouldBe("path");
        lut.Params.Single().Key.ShouldBe("intensity");
    }

    [Fact]
    public void CurvesAndHueCurvesHaveNoNumericParams()
    {
        EffectRegistry.Descriptor("color.curves")!.Params.ShouldBeEmpty();
        EffectRegistry.Descriptor("color.hueCurves")!.Params.ShouldBeEmpty();
    }

    [Fact]
    public void MakeEffectPopulatesEveryParamWithItsDefault()
    {
        var descriptor = EffectRegistry.Descriptor("stylize.vignette")!;
        var effect = descriptor.MakeEffect();

        effect.Type.ShouldBe("stylize.vignette");
        effect.Enabled.ShouldBeTrue();
        foreach (var spec in descriptor.Params)
        {
            effect.Params[spec.Key].Value.ShouldBe(spec.DefaultValue);
        }
    }

    [Fact]
    public void CanonicalOrderContainsExactlyEveryRegisteredId()
    {
        EffectRegistry.CanonicalOrder.Count.ShouldBe(20);
        EffectRegistry.CanonicalOrder.OrderBy(x => x, StringComparer.Ordinal)
            .ShouldBe(EffectRegistry.All.Select(d => d.Id).OrderBy(x => x, StringComparer.Ordinal));
    }

    [Fact]
    public void InsertIndexPlacesANewEffectBeforeTheFirstLowerRankedEntry()
    {
        // stylize.vignette outranks stylize.glow in canonicalOrder — inserting vignette into a
        // stack that already has glow must land before it, matching EffectRegistry.swift's
        // `insertIndex`.
        var existing = new List<Models.Effect> { EffectRegistry.Descriptor("stylize.glow")!.MakeEffect() };

        var index = EffectRegistry.InsertIndex(existing, "stylize.vignette");

        index.ShouldBe(0);
    }

    [Fact]
    public void InsertIndexAppendsWhenNothingOutranksIt()
    {
        var existing = new List<Models.Effect> { EffectRegistry.Descriptor("color.exposure")!.MakeEffect() };

        var index = EffectRegistry.InsertIndex(existing, "stylize.glow");

        index.ShouldBe(1);
    }
}
