using PalmierPro.Core.Serialization;

namespace PalmierPro.Core.Models;

/// <summary>Resolve-style hue curves: each maps source hue (0…1, cyclic) to one adjustment.</summary>
public sealed class HueCurves
{
    public List<CurvePoint> HueVsHue { get; set; } = [];
    public List<CurvePoint> HueVsSat { get; set; } = [];
    public List<CurvePoint> HueVsLum { get; set; } = [];

    public enum Channel
    {
        Hue,
        Sat,
        Lum,
    }

    public const double NeutralY = 0.5;
    public const string EffectType = "color.hueCurves";
    public static readonly IReadOnlyList<CurvePoint> DefaultPoints =
        Enumerable.Range(0, 6).Select(i => new CurvePoint(i / 6.0, NeutralY)).ToList();

    public List<CurvePoint> Points(Channel c) => c switch
    {
        Channel.Hue => HueVsHue,
        Channel.Sat => HueVsSat,
        _ => HueVsLum,
    };

    public void Set(Channel c, List<CurvePoint> pts)
    {
        switch (c)
        {
            case Channel.Hue: HueVsHue = pts; break;
            case Channel.Sat: HueVsSat = pts; break;
            default: HueVsLum = pts; break;
        }
    }

    public static bool IsNeutral(IReadOnlyList<CurvePoint> pts)
        => pts.Count == 0 || pts.All(p => Math.Abs(p.Y - NeutralY) < 1e-4);

    /// <summary>All curves flat → no effect to render or persist.</summary>
    public bool IsIdentity => IsNeutral(HueVsHue) && IsNeutral(HueVsSat) && IsNeutral(HueVsLum);

    /// <summary>Cyclic piecewise-linear eval — wraps across the hue seam so the curve is seamless at 0/1.</summary>
    public static double Eval(IReadOnlyList<CurvePoint> pts, double x)
    {
        var p = (pts.Count == 0 ? DefaultPoints : pts).OrderBy(pt => pt.X).ToList();
        if (p.Count == 0) return NeutralY;
        var first = p[0];
        var last = p[^1];
        if (x < first.X) return Lerp(new CurvePoint(last.X - 1, last.Y), first, x);
        for (var i = 1; i < p.Count; i++)
        {
            if (x <= p[i].X) return Lerp(p[i - 1], p[i], x);
        }
        return Lerp(last, new CurvePoint(first.X + 1, first.Y), x);
    }

    private static double Lerp(CurvePoint a, CurvePoint b, double x)
    {
        var t = b.X - a.X == 0 ? 0 : (x - a.X) / (b.X - a.X);
        return a.Y + (b.Y - a.Y) * t;
    }

    public string? Encoded()
    {
        try
        {
            return PalmierJson.EncodeToString(this);
        }
        catch
        {
            return null;
        }
    }

    public static HueCurves? FromJson(string json)
    {
        try
        {
            return PalmierJson.Decode<HueCurves>(json);
        }
        catch
        {
            return null;
        }
    }

    public static HueCurves Read(IReadOnlyList<Effect> effects)
    {
        var json = effects.FirstOrDefault(e => e.Type == EffectType)?.Params.GetValueOrDefault("curves")?.String;
        return json is null ? new HueCurves() : FromJson(json) ?? new HueCurves();
    }

    /// <summary>Write this into <paramref name="effects"/>, or remove it when there's nothing to keep.</summary>
    public void Upsert(List<Effect> effects)
    {
        var existing = effects.FindIndex(e => e.Type == EffectType);
        if (IsIdentity || Encoded() is not { } json)
        {
            if (existing >= 0) effects.RemoveAt(existing);
            return;
        }
        if (existing >= 0)
        {
            effects[existing].Params["curves"] = new EffectParam { String = json };
        }
        else
        {
            var effect = new Effect { Type = EffectType };
            effect.Params["curves"] = new EffectParam { String = json };
            effects.Add(effect);
        }
    }
}
