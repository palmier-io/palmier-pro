using PalmierPro.Core.Models;

namespace PalmierPro.Core.Compositing;

public sealed record EffectParamSpec(
    string Key, string Label, double Min, double Max, double DefaultValue, string Unit = "");

/// <summary>Numeric/string params resolved for one clip-relative frame offset.</summary>
public sealed class ResolvedEffectParams
{
    public required Dictionary<string, double> Values { get; init; }
    public required Dictionary<string, string> Strings { get; init; }
    public int Frame { get; init; }

    public double Value(string key) => Values.GetValueOrDefault(key);
    public string? String(string key) => Strings.GetValueOrDefault(key);
}

public sealed class EffectDescriptor
{
    public required string Id { get; init; }
    public required string DisplayName { get; init; }
    public required string Category { get; init; }
    public required IReadOnlyList<EffectParamSpec> Params { get; init; }
    public bool Linearizes { get; init; }
    public string? ResourceKey { get; init; }

    public Effect MakeEffect()
    {
        var effect = new Effect { Type = Id };
        foreach (var spec in Params)
            effect.Params[spec.Key] = new EffectParam { Value = spec.DefaultValue };
        return effect;
    }

    public ResolvedEffectParams Resolve(Effect effect, int offset)
    {
        var values = new Dictionary<string, double>(Params.Count);
        foreach (var spec in Params)
        {
            var raw = effect.Params.TryGetValue(spec.Key, out var param)
                ? param.Resolved(offset, spec.DefaultValue)
                : spec.DefaultValue;
            values[spec.Key] = Math.Clamp(raw, spec.Min, spec.Max);
        }
        var strings = effect.Params
            .Where(kv => kv.Value.String is not null)
            .ToDictionary(kv => kv.Key, kv => kv.Value.String!);
        return new ResolvedEffectParams { Values = values, Strings = strings, Frame = offset };
    }
}

/// <summary>Catalog of clip effects. Apply logic lives in Media; this owns IDs, ranges, and resolution.</summary>
public static class EffectRegistry
{
    public static readonly string[] CanonicalOrder =
    [
        "color.exposure", "color.contrast", "color.highlightsShadows", "color.blacksWhites",
        "color.temperature", "color.vibrance", "color.saturation", "color.wheels", "color.curves",
        "color.hueCurves", "color.lut", "detail.clarity", "key.chroma", "blur.gaussian", "blur.sharpen",
        "blur.noiseReduction", "blur.motion", "stylize.invert", "stylize.grain", "stylize.vignette",
        "stylize.glow",
    ];

    // Category arrays must be declared before All — static field init is textual order.
    private static readonly EffectDescriptor[] Color =
    [
        Spec("color.exposure", "Exposure", "Color",
            [new("ev", "Exposure", -3, 3, 0)], linearizes: true),
        Spec("color.contrast", "Contrast", "Color",
            [new("amount", "Contrast", 0.5, 1.5, 1)]),
        Spec("color.saturation", "Saturation", "Color",
            [new("amount", "Saturation", 0, 2, 1)]),
        Spec("color.temperature", "Temperature & Tint", "Color",
        [
            new("temperature", "Temperature", 2000, 11000, 6500, "K"),
            new("tint", "Tint", -100, 100, 0),
        ]),
        Spec("color.highlightsShadows", "Highlights & Shadows", "Color",
        [
            new("highlights", "Highlights", -1, 1, 0),
            new("shadows", "Shadows", -1, 1, 0),
        ]),
        Spec("color.blacksWhites", "Levels", "Color",
        [
            new("blacks", "Blacks", -1, 1, 0),
            new("whites", "Whites", -1, 1, 0),
        ]),
        Spec("color.vibrance", "Vibrance", "Color",
            [new("amount", "Vibrance", -1, 1, 0)]),
    ];

    private static readonly EffectDescriptor[] Wheels =
    [
        Spec("color.wheels", "Color Wheels", "Color",
        [
            new("lift_x", "Lift", -1, 1, 0), new("lift_y", "Lift", -1, 1, 0),
            new("lift_m", "Lift", -0.5, 0.5, 0),
            new("gamma_x", "Gamma", -1, 1, 0), new("gamma_y", "Gamma", -1, 1, 0),
            new("gamma_m", "Gamma", 0.5, 2, 1),
            new("gain_x", "Gain", -1, 1, 0), new("gain_y", "Gain", -1, 1, 0),
            new("gain_m", "Gain", 0.5, 1.5, 1),
        ]),
    ];

    private static readonly EffectDescriptor[] HueCurves =
    [
        Spec("color.hueCurves", "Hue Curves", "Color", []),
    ];

    private static readonly EffectDescriptor[] Lut =
    [
        Spec("color.lut", "LUT", "Color",
            [new("intensity", "Intensity", 0, 1, 1)], resourceKey: "path"),
    ];

    private static readonly EffectDescriptor[] Curves =
    [
        Spec("color.curves", "Curves", "Color", []),
    ];

    private static readonly EffectDescriptor[] Blur =
    [
        Spec("blur.gaussian", "Gaussian Blur", "Blur & Sharpen",
            [new("radius", "Radius", 0, 100, 8, "px")]),
        Spec("blur.sharpen", "Sharpen", "Blur & Sharpen",
            [new("amount", "Sharpness", 0, 2, 0.4)]),
        Spec("blur.noiseReduction", "Noise Reduction", "Blur & Sharpen",
            [new("amount", "Noise Reduction", 0, 1, 0)]),
        Spec("blur.motion", "Motion Blur", "Blur & Sharpen",
        [
            new("radius", "Motion Blur", 0, 100, 0, "px"),
            new("angle", "Angle", -180, 180, 0, "°"),
        ]),
    ];

    private static readonly EffectDescriptor[] Stylize =
    [
        Spec("stylize.invert", "Invert", "Stylize", []),
        Spec("stylize.grain", "Film Grain", "Stylize",
        [
            new("amount", "Amount", 0, 1, 0),
            new("size", "Size", 0.5, 4, 1.5),
        ]),
        Spec("stylize.vignette", "Vignette", "Stylize",
        [
            new("amount", "Amount", -1, 1, 0),
            new("midpoint", "Midpoint", 0, 1, 0.5),
            new("roundness", "Roundness", -1, 1, 0),
            new("feather", "Feather", 0, 1, 0.5),
        ]),
        Spec("stylize.glow", "Glow", "Stylize",
        [
            new("intensity", "Glow", 0, 1, 0),
            new("radius", "Radius", 0, 100, 20, "px"),
            new("threshold", "Threshold", 0, 1, 0.6),
            new("warmth", "Warmth", 0, 1, 0),
        ]),
    ];

    private static readonly EffectDescriptor[] Detail =
    [
        Spec("detail.clarity", "Clarity & Haze", "Detail",
        [
            new("clarity", "Clarity", -1, 1, 0),
            new("dehaze", "Dehaze", -1, 1, 0),
        ]),
    ];

    private static readonly EffectDescriptor[] Key =
    [
        Spec("key.chroma", "Chroma Key", "Key",
        [
            new("keyHue", "Key Hue", 0, 1, 0.333),
            new("tolerance", "Tolerance", 0, 1, 0),
            new("softness", "Softness", 0, 1, 0.1),
            new("spill", "Spill", 0, 1, 0.5),
        ]),
    ];

    public static IReadOnlyList<EffectDescriptor> All { get; } =
    [
        .. Color, .. Wheels, .. HueCurves, .. Lut, .. Curves, .. Detail, .. Blur, .. Stylize, .. Key,
    ];

    public static IReadOnlyDictionary<string, EffectDescriptor> ById { get; } =
        All.ToDictionary(d => d.Id);

    public static EffectDescriptor? Descriptor(string id)
        => ById.TryGetValue(id, out var d) ? d : null;

    public static int InsertIndex(IReadOnlyList<Effect> effects, string id)
    {
        var rank = Array.IndexOf(CanonicalOrder, id);
        if (rank < 0) rank = int.MaxValue;
        for (var i = 0; i < effects.Count; i++)
        {
            var other = Array.IndexOf(CanonicalOrder, effects[i].Type);
            if (other < 0) other = int.MaxValue;
            if (other > rank) return i;
        }
        return effects.Count;
    }

    private static EffectDescriptor Spec(
        string id, string name, string category, EffectParamSpec[] params_,
        bool linearizes = false, string? resourceKey = null)
        => new()
        {
            Id = id,
            DisplayName = name,
            Category = category,
            Params = params_,
            Linearizes = linearizes,
            ResourceKey = resourceKey,
        };
}
