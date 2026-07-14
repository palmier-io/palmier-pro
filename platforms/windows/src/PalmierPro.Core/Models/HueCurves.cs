using System.Text.Json;
using System.Text.Json.Serialization;

namespace PalmierPro.Core.Models;

/// `HueCurves.Channel` — flattened to a top-level type per this port's nested-type convention (see
/// MulticamSource.cs). Not Codable in Swift — a UI picker grouping, never persisted directly.
public enum HueCurvesChannel
{
    Hue,
    Sat,
    Lum,
}

public static class HueCurvesChannelExtensions
{
    public static string RawValue(this HueCurvesChannel channel) => channel switch
    {
        HueCurvesChannel.Hue => "Hue",
        HueCurvesChannel.Sat => "Sat",
        HueCurvesChannel.Lum => "Luma",
        _ => throw new ArgumentOutOfRangeException(nameof(channel)),
    };
}

/// Resolve-style hue curves: each maps source hue (0…1, cyclic) to one adjustment. Plain Codable in
/// Swift, no custom init: all three fields required on decode.
public sealed class HueCurves
{
    public const double NeutralY = 0.5;
    public const string EffectType = "color.hueCurves";

    [JsonPropertyName("hueVsHue")]
    [JsonRequired]
    public List<CurvePoint> HueVsHue { get; set; } = []; // -> hue rotation

    [JsonPropertyName("hueVsSat")]
    [JsonRequired]
    public List<CurvePoint> HueVsSat { get; set; } = []; // -> saturation scale

    [JsonPropertyName("hueVsLum")]
    [JsonRequired]
    public List<CurvePoint> HueVsLum { get; set; } = []; // -> luminance shift

    public static readonly IReadOnlyList<CurvePoint> DefaultPoints =
        Enumerable.Range(0, 6).Select(i => new CurvePoint((double)i / 6, NeutralY)).ToList();

    public List<CurvePoint> Points(HueCurvesChannel channel) => channel switch
    {
        HueCurvesChannel.Hue => HueVsHue,
        HueCurvesChannel.Sat => HueVsSat,
        HueCurvesChannel.Lum => HueVsLum,
        _ => throw new ArgumentOutOfRangeException(nameof(channel)),
    };

    public void Set(HueCurvesChannel channel, List<CurvePoint> points)
    {
        switch (channel)
        {
            case HueCurvesChannel.Hue: HueVsHue = points; break;
            case HueCurvesChannel.Sat: HueVsSat = points; break;
            case HueCurvesChannel.Lum: HueVsLum = points; break;
            default: throw new ArgumentOutOfRangeException(nameof(channel));
        }
    }

    public static bool IsNeutral(IReadOnlyList<CurvePoint> pts) =>
        pts.Count == 0 || pts.All(p => Math.Abs(p.Y - NeutralY) < 1e-4);

    /// All curves flat -> no effect to render or persist.
    [JsonIgnore]
    public bool IsIdentity => IsNeutral(HueVsHue) && IsNeutral(HueVsSat) && IsNeutral(HueVsLum);

    /// Cyclic piecewise-linear eval — wraps across the hue seam so the curve is seamless at 0/1.
    public static double Eval(IReadOnlyList<CurvePoint> pts, double x)
    {
        var p = (pts.Count == 0 ? DefaultPoints : pts).OrderBy(pt => pt.X).ToList();
        if (p.Count == 0)
        {
            return NeutralY;
        }
        var first = p[0];
        var last = p[^1];
        if (x < first.X)
        {
            return Lerp(new CurvePoint(last.X - 1, last.Y), first, x);
        }
        for (var i = 1; i < p.Count; i++)
        {
            if (x <= p[i].X)
            {
                return Lerp(p[i - 1], p[i], x);
            }
        }
        return Lerp(last, new CurvePoint(first.X + 1, first.Y), x);
    }

    private static double Lerp(CurvePoint a, CurvePoint b, double x)
    {
        var t = b.X - a.X == 0 ? 0 : (x - a.X) / (b.X - a.X);
        return a.Y + (b.Y - a.Y) * t;
    }

    public string? ToJson()
    {
        try
        {
            return JsonSerializer.Serialize(this);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static HueCurves? FromJson(string json)
    {
        try
        {
            return JsonSerializer.Deserialize<HueCurves>(json);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static HueCurves Read(List<Effect> effects)
    {
        var json = effects.FirstOrDefault(e => e.Type == EffectType)?.Params.GetValueOrDefault("curves")?.StringValue;
        if (json is null)
        {
            return new HueCurves();
        }
        return FromJson(json) ?? new HueCurves();
    }

    /// Write `self` into `effects` (canonical order), or remove it when there's nothing to keep.
    public void Upsert(List<Effect> effects)
    {
        var existingIndex = effects.FindIndex(e => e.Type == EffectType);
        var json = ToJson();
        if (IsIdentity || json is null)
        {
            if (existingIndex >= 0)
            {
                effects.RemoveAt(existingIndex);
            }
            return;
        }
        if (existingIndex >= 0)
        {
            effects[existingIndex].Params["curves"] = new EffectParam(stringValue: json);
        }
        else
        {
            var effect = new Effect(EffectType);
            effect.Params["curves"] = new EffectParam(stringValue: json);
            effects.Insert(EffectCanonicalOrder.InsertIndex(effects, EffectType), effect);
        }
    }
}

/// Mirrors only the effect-ordering half of Compositing/EffectRegistry.swift — the full effect
/// catalog (descriptors, HLSL/Metal apply closures) is a rendering-layer concern ported later;
/// `HueCurves.Upsert` only needs to know where "color.hueCurves" belongs in the canonical
/// adjustment-stack order.
internal static class EffectCanonicalOrder
{
    private static readonly string[] Order =
    [
        "color.exposure", "color.contrast", "color.highlightsShadows", "color.blacksWhites",
        "color.temperature", "color.vibrance", "color.saturation", "color.wheels", "color.curves",
        "color.hueCurves", "color.lut", "detail.clarity", "key.chroma", "blur.gaussian", "blur.sharpen",
        "blur.noiseReduction", "blur.motion", "stylize.grain", "stylize.vignette", "stylize.glow",
    ];

    public static int InsertIndex(List<Effect> effects, string id)
    {
        var rank = Array.IndexOf(Order, id);
        if (rank < 0)
        {
            rank = int.MaxValue;
        }
        for (var i = 0; i < effects.Count; i++)
        {
            var effectRank = Array.IndexOf(Order, effects[i].Type);
            if (effectRank < 0)
            {
                effectRank = int.MaxValue;
            }
            if (effectRank > rank)
            {
                return i;
            }
        }
        return effects.Count;
    }
}
