namespace PalmierPro.Core.Compositing;

/// <summary>Lift/Gamma/Gain wheel math mirroring Mac ColorWheels.swift.</summary>
public static class ColorWheels
{
    private const double ChromaLift = 0.2;
    private const double ChromaGain = 0.35;
    private const double ChromaGamma = 0.35;

    public readonly record struct Coefficients(
        (float R, float G, float B) Lift,
        (float R, float G, float B) Gain,
        (float R, float G, float B) InvGamma);

    public static (double R, double G, double B) HueRgb(double h)
    {
        var x = (h - Math.Floor(h)) * 6;
        var f = x - Math.Floor(x);
        return ((int)x % 6) switch
        {
            0 => (1, f, 0),
            1 => (1 - f, 1, 0),
            2 => (0, 1, f),
            3 => (0, 1 - f, 1),
            4 => (f, 0, 1),
            _ => (1, 0, 1 - f),
        };
    }

    public static (double R, double G, double B) ChromaOffset(double x, double y)
    {
        var r = Math.Min(1, Math.Sqrt(x * x + y * y));
        if (r <= 1e-6) return (0, 0, 0);
        var (cr, cg, cb) = HueRgb(Math.Atan2(y, x) / (2 * Math.PI));
        var mean = (cr + cg + cb) / 3;
        return ((cr - mean) * r, (cg - mean) * r, (cb - mean) * r);
    }

    public static bool IsNeutral(ResolvedEffectParams p)
        => p.Value("lift_x") == 0 && p.Value("lift_y") == 0 && p.Value("lift_m") == 0
            && p.Value("gamma_x") == 0 && p.Value("gamma_y") == 0 && p.Value("gamma_m") == 1
            && p.Value("gain_x") == 0 && p.Value("gain_y") == 0 && p.Value("gain_m") == 1;

    public static Coefficients CoefficientsFor(ResolvedEffectParams p)
    {
        var lift = ChromaOffset(p.Value("lift_x"), p.Value("lift_y"));
        var gamma = ChromaOffset(p.Value("gamma_x"), p.Value("gamma_y"));
        var gain = ChromaOffset(p.Value("gain_x"), p.Value("gain_y"));
        var liftM = p.Value("lift_m");
        var gammaM = p.Value("gamma_m");
        var gainM = p.Value("gain_m");
        float L(double c) => (float)(liftM + c * ChromaLift);
        float G(double c) => (float)(gainM * (1 + c * ChromaGain));
        float Ig(double c) => (float)(1 / Math.Max(0.01, gammaM * (1 + c * ChromaGamma)));
        return new Coefficients(
            (L(lift.R), L(lift.G), L(lift.B)),
            (G(gain.R), G(gain.G), G(gain.B)),
            (Ig(gamma.R), Ig(gamma.G), Ig(gamma.B)));
    }
}
