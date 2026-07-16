using PalmierPro.Core.Models;

namespace PalmierPro.Core.Effects;

/// One numeric parameter's authoring range/default. Ported verbatim from `EffectParamSpec` in
/// Sources/PalmierPro/Compositing/EffectRegistry.swift (key/label/range/defaultValue/unit — the
/// same five fields, C# can't express a `ClosedRange&lt;Double&gt;` so it's split into Min/Max).
public sealed class EffectParamSpec
{
    public required string Key { get; init; }
    public required string Label { get; init; }
    public required double RangeMin { get; init; }
    public required double RangeMax { get; init; }
    public required double DefaultValue { get; init; }
    public required string Unit { get; init; }
}

/// Catalog entry: id/display name/category/param specs. Mirrors `EffectDescriptor` in
/// EffectRegistry.swift minus `apply`/`linearizes` — those are CIImage rendering concerns with no
/// C# analog (rendering is native; see native/EffectRegistry.h's 11-kernel subset). This side only
/// needs authoring metadata for the Inspector: the add-effect catalog, generated param rows.
public sealed class EffectDescriptor
{
    public required string Id { get; init; }
    public required string DisplayName { get; init; }
    public required string Category { get; init; }
    public required IReadOnlyList<EffectParamSpec> Params { get; init; }

    /// Non-null for effects carrying a file resource (LUT) — mirrors `EffectDescriptor.resourceKey`,
    /// drives the file-choose row instead of a plain slider.
    public string? ResourceKey { get; init; }

    /// Default Effect instance for "Add Effect". Mirrors `EffectDescriptor.makeEffect()`.
    public Effect MakeEffect()
    {
        var effect = new Effect(Id);
        foreach (var spec in Params)
        {
            effect.Params[spec.Key] = new EffectParam(spec.DefaultValue);
        }
        return effect;
    }
}

/// C# mirror of Sources/PalmierPro/Compositing/EffectRegistry.swift's `EffectRegistry` enum — same
/// catalog (every effect type, display name, param specs/ranges/defaults, grouping), same `all`
/// concatenation order, same `canonicalOrder`/`insertIndex`. Comments on each descriptor point at
/// the exact Swift declaration ported. Only 11 of these 20 entries have a native Windows renderer
/// today (native/EffectRegistry.cpp's Metal-kernel subset — the rest are CIFilter-only wrappers on
/// the Mac, out of E3's port scope per that file's own header comment); `EffectRegistryTests`
/// cross-checks this file's data against native/EffectRegistry.cpp's literals for that subset so
/// Swift/native/C# stay in sync. Effects outside that subset still belong in the catalog (an
/// EffectRegistry.swift port with fewer than all 20 entries would silently diverge the moment
/// native support grows) — GpuCompositor::ApplyEffectChain already no-ops unregistered types rather
/// than failing, so adding one from the Windows catalog today is inert, not broken.
public static class EffectRegistry
{
    public static readonly IReadOnlyList<EffectDescriptor> All =
    [
        // MARK: - Color (EffectRegistry.swift:82-157 `color`)
        new EffectDescriptor
        {
            Id = "color.exposure", DisplayName = "Exposure", Category = "Color",
            Params = [new EffectParamSpec { Key = "ev", Label = "Exposure", RangeMin = -3, RangeMax = 3, DefaultValue = 0, Unit = "" }],
        },
        new EffectDescriptor
        {
            Id = "color.contrast", DisplayName = "Contrast", Category = "Color",
            Params = [new EffectParamSpec { Key = "amount", Label = "Contrast", RangeMin = 0.5, RangeMax = 1.5, DefaultValue = 1, Unit = "" }],
        },
        new EffectDescriptor
        {
            Id = "color.saturation", DisplayName = "Saturation", Category = "Color",
            Params = [new EffectParamSpec { Key = "amount", Label = "Saturation", RangeMin = 0, RangeMax = 2, DefaultValue = 1, Unit = "" }],
        },
        new EffectDescriptor
        {
            Id = "color.temperature", DisplayName = "Temperature & Tint", Category = "Color",
            Params =
            [
                new EffectParamSpec { Key = "temperature", Label = "Temperature", RangeMin = 2000, RangeMax = 11000, DefaultValue = 6500, Unit = "K" },
                new EffectParamSpec { Key = "tint", Label = "Tint", RangeMin = -100, RangeMax = 100, DefaultValue = 0, Unit = "" },
            ],
        },
        new EffectDescriptor
        {
            Id = "color.highlightsShadows", DisplayName = "Highlights & Shadows", Category = "Color",
            Params =
            [
                new EffectParamSpec { Key = "highlights", Label = "Highlights", RangeMin = -1, RangeMax = 1, DefaultValue = 0, Unit = "" },
                new EffectParamSpec { Key = "shadows", Label = "Shadows", RangeMin = -1, RangeMax = 1, DefaultValue = 0, Unit = "" },
            ],
        },
        new EffectDescriptor
        {
            Id = "color.blacksWhites", DisplayName = "Levels", Category = "Color",
            Params =
            [
                new EffectParamSpec { Key = "blacks", Label = "Blacks", RangeMin = -1, RangeMax = 1, DefaultValue = 0, Unit = "" },
                new EffectParamSpec { Key = "whites", Label = "Whites", RangeMin = -1, RangeMax = 1, DefaultValue = 0, Unit = "" },
            ],
        },
        new EffectDescriptor
        {
            Id = "color.vibrance", DisplayName = "Vibrance", Category = "Color",
            Params = [new EffectParamSpec { Key = "amount", Label = "Vibrance", RangeMin = -1, RangeMax = 1, DefaultValue = 0, Unit = "" }],
        },

        // MARK: - Color wheels (EffectRegistry.swift:159-177 `wheels`)
        new EffectDescriptor
        {
            Id = "color.wheels", DisplayName = "Color Wheels", Category = "Color",
            Params =
            [
                new EffectParamSpec { Key = "lift_x", Label = "Lift", RangeMin = -1, RangeMax = 1, DefaultValue = 0, Unit = "" },
                new EffectParamSpec { Key = "lift_y", Label = "Lift", RangeMin = -1, RangeMax = 1, DefaultValue = 0, Unit = "" },
                new EffectParamSpec { Key = "lift_m", Label = "Lift", RangeMin = -0.5, RangeMax = 0.5, DefaultValue = 0, Unit = "" },
                new EffectParamSpec { Key = "gamma_x", Label = "Gamma", RangeMin = -1, RangeMax = 1, DefaultValue = 0, Unit = "" },
                new EffectParamSpec { Key = "gamma_y", Label = "Gamma", RangeMin = -1, RangeMax = 1, DefaultValue = 0, Unit = "" },
                new EffectParamSpec { Key = "gamma_m", Label = "Gamma", RangeMin = 0.5, RangeMax = 2, DefaultValue = 1, Unit = "" },
                new EffectParamSpec { Key = "gain_x", Label = "Gain", RangeMin = -1, RangeMax = 1, DefaultValue = 0, Unit = "" },
                new EffectParamSpec { Key = "gain_y", Label = "Gain", RangeMin = -1, RangeMax = 1, DefaultValue = 0, Unit = "" },
                new EffectParamSpec { Key = "gain_m", Label = "Gain", RangeMin = 0.5, RangeMax = 1.5, DefaultValue = 1, Unit = "" },
            ],
        },

        // MARK: - Hue curves (EffectRegistry.swift:179-188 `hueCurves`)
        new EffectDescriptor { Id = "color.hueCurves", DisplayName = "Hue Curves", Category = "Color", Params = [] },

        // MARK: - LUT (EffectRegistry.swift:190-201 `lut`)
        new EffectDescriptor
        {
            Id = "color.lut", DisplayName = "LUT", Category = "Color",
            Params = [new EffectParamSpec { Key = "intensity", Label = "Intensity", RangeMin = 0, RangeMax = 1, DefaultValue = 1, Unit = "" }],
            ResourceKey = "path",
        },

        // MARK: - Curves (EffectRegistry.swift:203-212 `curves`)
        new EffectDescriptor { Id = "color.curves", DisplayName = "Curves", Category = "Color", Params = [] },

        // MARK: - Detail (EffectRegistry.swift:314-325 `detail`)
        new EffectDescriptor
        {
            Id = "detail.clarity", DisplayName = "Clarity & Haze", Category = "Detail",
            Params =
            [
                new EffectParamSpec { Key = "clarity", Label = "Clarity", RangeMin = -1, RangeMax = 1, DefaultValue = 0, Unit = "" },
                new EffectParamSpec { Key = "dehaze", Label = "Dehaze", RangeMin = -1, RangeMax = 1, DefaultValue = 0, Unit = "" },
            ],
        },

        // MARK: - Blur & Sharpen (EffectRegistry.swift:214-271 `blur`)
        new EffectDescriptor
        {
            Id = "blur.gaussian", DisplayName = "Gaussian Blur", Category = "Blur & Sharpen",
            Params = [new EffectParamSpec { Key = "radius", Label = "Radius", RangeMin = 0, RangeMax = 100, DefaultValue = 8, Unit = "px" }],
        },
        new EffectDescriptor
        {
            Id = "blur.sharpen", DisplayName = "Sharpen", Category = "Blur & Sharpen",
            Params = [new EffectParamSpec { Key = "amount", Label = "Sharpness", RangeMin = 0, RangeMax = 2, DefaultValue = 0.4, Unit = "" }],
        },
        new EffectDescriptor
        {
            Id = "blur.noiseReduction", DisplayName = "Noise Reduction", Category = "Blur & Sharpen",
            Params = [new EffectParamSpec { Key = "amount", Label = "Noise Reduction", RangeMin = 0, RangeMax = 1, DefaultValue = 0, Unit = "" }],
        },
        new EffectDescriptor
        {
            Id = "blur.motion", DisplayName = "Motion Blur", Category = "Blur & Sharpen",
            Params =
            [
                new EffectParamSpec { Key = "radius", Label = "Motion Blur", RangeMin = 0, RangeMax = 100, DefaultValue = 0, Unit = "px" },
                new EffectParamSpec { Key = "angle", Label = "Angle", RangeMin = -180, RangeMax = 180, DefaultValue = 0, Unit = "°" },
            ],
        },

        // MARK: - Stylize (EffectRegistry.swift:273-312 `stylize`)
        new EffectDescriptor
        {
            Id = "stylize.grain", DisplayName = "Film Grain", Category = "Stylize",
            Params =
            [
                new EffectParamSpec { Key = "amount", Label = "Amount", RangeMin = 0, RangeMax = 1, DefaultValue = 0, Unit = "" },
                new EffectParamSpec { Key = "size", Label = "Size", RangeMin = 0.5, RangeMax = 4, DefaultValue = 1.5, Unit = "" },
            ],
        },
        new EffectDescriptor
        {
            Id = "stylize.vignette", DisplayName = "Vignette", Category = "Stylize",
            Params =
            [
                new EffectParamSpec { Key = "amount", Label = "Amount", RangeMin = -1, RangeMax = 1, DefaultValue = 0, Unit = "" },
                new EffectParamSpec { Key = "midpoint", Label = "Midpoint", RangeMin = 0, RangeMax = 1, DefaultValue = 0.5, Unit = "" },
                new EffectParamSpec { Key = "roundness", Label = "Roundness", RangeMin = -1, RangeMax = 1, DefaultValue = 0, Unit = "" },
                new EffectParamSpec { Key = "feather", Label = "Feather", RangeMin = 0, RangeMax = 1, DefaultValue = 0.5, Unit = "" },
            ],
        },
        new EffectDescriptor
        {
            Id = "stylize.glow", DisplayName = "Glow", Category = "Stylize",
            Params =
            [
                new EffectParamSpec { Key = "intensity", Label = "Glow", RangeMin = 0, RangeMax = 1, DefaultValue = 0, Unit = "" },
                new EffectParamSpec { Key = "radius", Label = "Radius", RangeMin = 0, RangeMax = 100, DefaultValue = 20, Unit = "px" },
                new EffectParamSpec { Key = "threshold", Label = "Threshold", RangeMin = 0, RangeMax = 1, DefaultValue = 0.6, Unit = "" },
                new EffectParamSpec { Key = "warmth", Label = "Warmth", RangeMin = 0, RangeMax = 1, DefaultValue = 0, Unit = "" },
            ],
        },

        // MARK: - Key (EffectRegistry.swift:327-341 `key`)
        new EffectDescriptor
        {
            Id = "key.chroma", DisplayName = "Chroma Key", Category = "Key",
            Params =
            [
                new EffectParamSpec { Key = "keyHue", Label = "Key Hue", RangeMin = 0, RangeMax = 1, DefaultValue = 0.333, Unit = "" },
                new EffectParamSpec { Key = "tolerance", Label = "Tolerance", RangeMin = 0, RangeMax = 1, DefaultValue = 0, Unit = "" },
                new EffectParamSpec { Key = "softness", Label = "Softness", RangeMin = 0, RangeMax = 1, DefaultValue = 0.1, Unit = "" },
                new EffectParamSpec { Key = "spill", Label = "Spill", RangeMin = 0, RangeMax = 1, DefaultValue = 0.5, Unit = "" },
            ],
        },
    ];

    public static readonly IReadOnlyDictionary<string, EffectDescriptor> ById =
        All.ToDictionary(d => d.Id);

    public static EffectDescriptor? Descriptor(string id) => ById.GetValueOrDefault(id);

    /// Grouped for the add-effect catalog flyout; category order and within-category order both
    /// mirror `All`'s (i.e. EffectRegistry.swift's `all`) concatenation order.
    public static readonly IReadOnlyList<(string Category, IReadOnlyList<EffectDescriptor> Effects)> ByCategory =
        [.. All
            .GroupBy(d => d.Category, StringComparer.Ordinal)
            .Select(g => (g.Key, (IReadOnlyList<EffectDescriptor>)[.. g]))];

    /// Mirrors EffectRegistry.swift's `canonicalOrder` — the always-on adjustment sections' insert
    /// order on the Mac; used here as the default insert position for "Add Effect" from the catalog.
    public static readonly IReadOnlyList<string> CanonicalOrder =
    [
        "color.exposure", "color.contrast", "color.highlightsShadows", "color.blacksWhites",
        "color.temperature", "color.vibrance", "color.saturation", "color.wheels", "color.curves",
        "color.hueCurves", "color.lut", "detail.clarity", "key.chroma", "blur.gaussian", "blur.sharpen",
        "blur.noiseReduction", "blur.motion", "stylize.grain", "stylize.vignette", "stylize.glow",
    ];

    private static readonly IReadOnlyDictionary<string, int> CanonicalRank =
        CanonicalOrder.Select((id, i) => (id, i)).ToDictionary(t => t.id, t => t.i);

    /// Canonical-order rank of an effect type — unregistered types sort last (int.MaxValue).
    /// Public so VideoEngine's SnapshotEffect-based insert (RefreshParams first-grade synthesis) can
    /// share the exact same ranking as <see cref="InsertIndex"/> instead of re-deriving it from
    /// CanonicalOrder (which, typed IReadOnlyList, has no IndexOf).
    public static int RankOf(string id) => CanonicalRank.TryGetValue(id, out var rank) ? rank : int.MaxValue;

    /// Mirrors EffectRegistry.swift's `insertIndex(_:for:)`.
    public static int InsertIndex(IReadOnlyList<Effect> effects, string id)
    {
        var rank = RankOf(id);
        for (var i = 0; i < effects.Count; i++)
        {
            if (RankOf(effects[i].Type) > rank)
            {
                return i;
            }
        }
        return effects.Count;
    }
}
