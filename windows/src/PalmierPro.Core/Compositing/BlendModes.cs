using PalmierPro.Core.Models;

namespace PalmierPro.Core.Compositing;

/// <summary>Photoshop-style blend equations used when compositing non-Normal layers.</summary>
public static class BlendModes
{
    public static (float R, float G, float B) Blend(
        BlendMode mode, float sr, float sg, float sb, float dr, float dg, float db)
        => mode switch
        {
            BlendMode.Darken => (Math.Min(sr, dr), Math.Min(sg, dg), Math.Min(sb, db)),
            BlendMode.Multiply => (sr * dr, sg * dg, sb * db),
            BlendMode.ColorBurn => (ColorBurn(sr, dr), ColorBurn(sg, dg), ColorBurn(sb, db)),
            BlendMode.Lighten => (Math.Max(sr, dr), Math.Max(sg, dg), Math.Max(sb, db)),
            BlendMode.Screen => (Screen(sr, dr), Screen(sg, dg), Screen(sb, db)),
            BlendMode.ColorDodge => (ColorDodge(sr, dr), ColorDodge(sg, dg), ColorDodge(sb, db)),
            BlendMode.Overlay => (Overlay(sr, dr), Overlay(sg, dg), Overlay(sb, db)),
            BlendMode.SoftLight => (SoftLight(sr, dr), SoftLight(sg, dg), SoftLight(sb, db)),
            BlendMode.HardLight => (Overlay(dr, sr), Overlay(dg, sg), Overlay(db, sb)),
            BlendMode.Difference => (Math.Abs(sr - dr), Math.Abs(sg - dg), Math.Abs(sb - db)),
            BlendMode.Exclusion => (Exclusion(sr, dr), Exclusion(sg, dg), Exclusion(sb, db)),
            BlendMode.Hue => Hue(sr, sg, sb, dr, dg, db),
            BlendMode.Saturation => Saturation(sr, sg, sb, dr, dg, db),
            BlendMode.Color => Color(sr, sg, sb, dr, dg, db),
            BlendMode.Luminosity => Luminosity(sr, sg, sb, dr, dg, db),
            _ => (sr, sg, sb),
        };

    private static float Screen(float s, float d) => 1f - (1f - s) * (1f - d);
    private static float Exclusion(float s, float d) => d + s - 2f * d * s;

    private static float ColorBurn(float s, float d)
    {
        if (s <= 0) return 0;
        return 1f - Math.Min(1f, (1f - d) / s);
    }

    private static float ColorDodge(float s, float d)
    {
        if (s >= 1) return 1;
        return Math.Min(1f, d / (1f - s));
    }

    private static float Overlay(float s, float d)
        => d < 0.5f ? 2f * s * d : 1f - 2f * (1f - s) * (1f - d);

    private static float SoftLight(float s, float d)
    {
        if (s < 0.5f) return d - (1f - 2f * s) * d * (1f - d);
        var w = d < 0.25f
            ? ((16f * d - 12f) * d + 4f) * d
            : MathF.Sqrt(d);
        return d + (2f * s - 1f) * (w - d);
    }

    private static (float R, float G, float B) Hue(float sr, float sg, float sb, float dr, float dg, float db)
    {
        var (_, ss, sv) = RgbToHsv(sr, sg, sb);
        var (dh, _, _) = RgbToHsv(dr, dg, db);
        return HsvToRgb(dh, ss, sv);
    }

    private static (float R, float G, float B) Saturation(
        float sr, float sg, float sb, float dr, float dg, float db)
    {
        var (_, ss, _) = RgbToHsv(sr, sg, sb);
        var (dh, _, dv) = RgbToHsv(dr, dg, db);
        return HsvToRgb(dh, ss, dv);
    }

    private static (float R, float G, float B) Color(
        float sr, float sg, float sb, float dr, float dg, float db)
    {
        var (sh, ss, _) = RgbToHsv(sr, sg, sb);
        var (_, _, dv) = RgbToHsv(dr, dg, db);
        return HsvToRgb(sh, ss, dv);
    }

    private static (float R, float G, float B) Luminosity(
        float sr, float sg, float sb, float dr, float dg, float db)
    {
        var (_, _, sv) = RgbToHsv(sr, sg, sb);
        var (dh, ds, _) = RgbToHsv(dr, dg, db);
        return HsvToRgb(dh, ds, sv);
    }

    private static (float H, float S, float V) RgbToHsv(float r, float g, float b)
    {
        var mx = Math.Max(r, Math.Max(g, b));
        var mn = Math.Min(r, Math.Min(g, b));
        var d = mx - mn;
        var h = 0f;
        if (d > 1e-6f)
        {
            if (mx == r) h = (g - b) / d + (g < b ? 6f : 0f);
            else if (mx == g) h = (b - r) / d + 2f;
            else h = (r - g) / d + 4f;
            h /= 6f;
        }
        var s = mx <= 1e-6f ? 0f : d / mx;
        return (h, s, mx);
    }

    private static (float R, float G, float B) HsvToRgb(float h, float s, float v)
    {
        var i = (int)Math.Floor(h * 6f);
        var f = h * 6f - i;
        var p = v * (1f - s);
        var q = v * (1f - f * s);
        var t = v * (1f - (1f - f) * s);
        return (i % 6) switch
        {
            0 => (v, t, p),
            1 => (q, v, p),
            2 => (p, v, t),
            3 => (p, q, v),
            4 => (t, p, v),
            _ => (v, p, q),
        };
    }
}
