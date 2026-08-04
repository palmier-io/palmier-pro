namespace PalmierPro.Core.Compositing;

/// <summary>
/// Per-pixel kernel math ported from Metal/*.metal. Operates on linear float RGB in 0…1
/// with separate alpha. Used by the Media EffectProcessor and parity tests.
/// </summary>
public static class EffectPixelKernels
{
    public static float Saturate(float v) => Math.Clamp(v, 0f, 1f);
    public static float Luma(float r, float g, float b) => 0.2126f * r + 0.7152f * g + 0.0722f * b;
    public static float Smoothstep(float edge0, float edge1, float x)
    {
        var t = Saturate((x - edge0) / Math.Max(1e-6f, edge1 - edge0));
        return t * t * (3f - 2f * t);
    }

    public static (float R, float G, float B) Levels(float r, float g, float b, float blacks, float whites)
    {
        if (blacks == 0 && whites == 0) return (r, g, b);
        var bp = -blacks * 0.4f;
        var wp = 1f - whites * 0.4f;
        var denom = Math.Max(0.05f, wp - bp);
        return (Saturate((r - bp) / denom), Saturate((g - bp) / denom), Saturate((b - bp) / denom));
    }

    public static (float R, float G, float B) HighlightsShadows(
        float r, float g, float b, float highlights, float shadows)
    {
        if (highlights == 0 && shadows == 0) return (r, g, b);
        var y = Luma(Saturate(r), Saturate(g), Saturate(b));
        var hi = y * y * y;
        var lo = (1f - y) * (1f - y) * (1f - y);
        var dY = (highlights * hi + shadows * lo) * 0.5f;
        return (Saturate(r + dY), Saturate(g + dY), Saturate(b + dY));
    }

    public static (float R, float G, float B) Exposure(float r, float g, float b, float ev)
    {
        if (ev == 0) return (r, g, b);
        var m = MathF.Pow(2f, ev);
        return (Saturate(r * m), Saturate(g * m), Saturate(b * m));
    }

    public static (float R, float G, float B) Contrast(float r, float g, float b, float amount)
    {
        if (Math.Abs(amount - 1f) < 1e-6f) return (r, g, b);
        // CIColorControls contrast pivots around 0.5.
        float C(float v) => Saturate((v - 0.5f) * amount + 0.5f);
        return (C(r), C(g), C(b));
    }

    public static (float R, float G, float B) Saturation(float r, float g, float b, float amount)
    {
        if (Math.Abs(amount - 1f) < 1e-6f) return (r, g, b);
        var y = Luma(r, g, b);
        return (
            Saturate(y + (r - y) * amount),
            Saturate(y + (g - y) * amount),
            Saturate(y + (b - y) * amount));
    }

    public static (float R, float G, float B) Invert(float r, float g, float b)
        => (1f - r, 1f - g, 1f - b);

    public static (float R, float G, float B) Wheels(
        float r, float g, float b, ColorWheels.Coefficients c)
    {
        float Channel(float v, float lift, float gain, float invGamma)
        {
            var lit = Math.Max(0f, v * (1f - lift) + lift) * gain;
            return Saturate(MathF.Pow(lit, invGamma));
        }
        return (
            Channel(r, c.Lift.R, c.Gain.R, c.InvGamma.R),
            Channel(g, c.Lift.G, c.Gain.G, c.InvGamma.G),
            Channel(b, c.Lift.B, c.Gain.B, c.InvGamma.B));
    }

    public static (float R, float G, float B, float A) ChromaKey(
        float r, float g, float b, float a,
        float keyHue, float tolerance, float softness, float spill)
    {
        var mx = Math.Max(r, Math.Max(g, b));
        var mn = Math.Min(r, Math.Min(g, b));
        var dd = mx - mn;
        var sat = mx <= 1e-5f ? 0f : dd / mx;
        var hue = 0f;
        if (dd > 1e-5f)
        {
            if (mx == r) hue = (g - b) / dd;
            else if (mx == g) hue = (b - r) / dd + 2f;
            else hue = (r - g) / dd + 4f;
            hue = hue / 6f;
            hue -= MathF.Floor(hue);
        }
        var hd = Math.Abs(hue - keyHue);
        hd = Math.Min(hd, 1f - hd);
        var inner = tolerance * 0.25f;
        var key = (1f - Smoothstep(inner, inner + softness * 0.3f + 0.02f, hd))
            * Smoothstep(0.12f, 0.32f, sat)
            * Smoothstep(0.04f, 0.12f, dd);
        var y = Luma(r, g, b);
        r = r + (y - r) * spill * key;
        g = g + (y - g) * spill * key;
        b = b + (y - b) * spill * key;
        return (r, g, b, a * (1f - key));
    }

    public static (float R, float G, float B) Vignette(
        float r, float g, float b,
        float px, float py, float width, float height,
        float amount, float midpoint, float roundness, float feather)
    {
        if (amount == 0 || width <= 0 || height <= 0) return (r, g, b);
        var cx = width * 0.5f;
        var cy = height * 0.5f;
        var dx = (px - cx) / Math.Max(cx, 1f);
        var dy = (py - cy) / Math.Max(cy, 1f);
        var p = Mix(6f, 2f, (roundness + 1f) * 0.5f);
        var dist = MathF.Pow(MathF.Pow(Math.Abs(dx), p) + MathF.Pow(Math.Abs(dy), p), 1f / p);
        var v = Smoothstep(midpoint, midpoint + feather * 1.5f + 0.05f, dist);
        var m = 1f + amount * v;
        return (Saturate(r * m), Saturate(g * m), Saturate(b * m));
    }

    public static float EdgeRoundingCoverage(
        float px, float py, float width, float height,
        float edgeRounding, float edgeSoftness)
    {
        var rounding = Saturate(edgeRounding);
        var softness = Saturate(edgeSoftness);
        if (rounding <= 0 && softness <= 0) return 1f;
        var radius = rounding * Math.Min(width, height) * 0.5f;
        var feather = softness * Math.Min(width, height) * 0.5f;
        var cx = width * 0.5f;
        var cy = height * 0.5f;
        var insetHalfW = width * 0.5f - radius;
        var insetHalfH = height * 0.5f - radius;
        var qx = Math.Abs(px - cx) - insetHalfW;
        var qy = Math.Abs(py - cy) - insetHalfH;
        var distance = MathF.Sqrt(Math.Max(qx, 0f) * Math.Max(qx, 0f) + Math.Max(qy, 0f) * Math.Max(qy, 0f))
            + Math.Min(Math.Max(qx, qy), 0f) - radius;
        return 1f - Smoothstep(-0.5f - feather, 0.5f, distance);
    }

    public static (float R, float G, float B) Grain(
        float r, float g, float b, float px, float py, float amount, float size, float frame)
    {
        if (amount <= 0) return (r, g, b);
        var coX = px / Math.Max(size, 0.5f);
        var coY = py / Math.Max(size, 0.5f);
        var n = Hash13(coX, coY, frame) - 0.5f;
        var y = Luma(r, g, b);
        var lumaMask = 4f * y * (1f - y);
        var delta = n * amount * 0.35f * lumaMask;
        return (Saturate(r + delta), Saturate(g + delta), Saturate(b + delta));
    }

    private static float Hash13(float x, float y, float z)
    {
        x = Fract(x * 0.1031f);
        y = Fract(y * 0.1031f);
        z = Fract(z * 0.1031f);
        var d = x * (z + 31.32f) + y * (x + 31.32f) + z * (y + 31.32f);
        x += d; y += d; z += d;
        return Fract((x + y) * z);
    }

    private static float Fract(float v) => v - MathF.Floor(v);
    private static float Mix(float a, float b, float t) => a + (b - a) * t;

    public static (float R, float G, float B) TemperatureTint(
        float r, float g, float b, float temperature, float tint)
    {
        // Approximate CITemperatureAndTint around D65: warm/cool along R/B, tint along G.
        if (Math.Abs(temperature - 6500f) < 1f && Math.Abs(tint) < 0.01f) return (r, g, b);
        var warm = Math.Clamp((temperature - 6500f) / 4500f, -1f, 1f);
        var t = Math.Clamp(tint / 100f, -1f, 1f);
        return (
            Saturate(r * (1f + warm * 0.15f)),
            Saturate(g * (1f - t * 0.08f)),
            Saturate(b * (1f - warm * 0.15f)));
    }

    public static (float R, float G, float B) Vibrance(float r, float g, float b, float amount)
    {
        if (amount == 0) return (r, g, b);
        var mx = Math.Max(r, Math.Max(g, b));
        var mn = Math.Min(r, Math.Min(g, b));
        var sat = mx <= 1e-5f ? 0f : (mx - mn) / mx;
        var scale = 1f + amount * (1f - sat);
        return Saturation(r, g, b, scale);
    }
}
