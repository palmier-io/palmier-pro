using PalmierPro.Core.Serialization;

namespace PalmierPro.Core.Models;

public record struct CurvePoint(double X, double Y);

/// <summary>Master (Rec.709 luma) + per-channel R/G/B tone curves.</summary>
public sealed class GradeCurve
{
    public List<CurvePoint> Master { get; set; } = [];
    public List<CurvePoint> Red { get; set; } = [];
    public List<CurvePoint> Green { get; set; } = [];
    public List<CurvePoint> Blue { get; set; } = [];

    public static readonly IReadOnlyList<CurvePoint> IdentityPoints = [new(0, 0), new(1, 1)];

    public bool IsIdentity =>
        new[] { Master, Red, Green, Blue }
            .All(points => points.Count == 0 || points.SequenceEqual(IdentityPoints));

    /// <summary>Piecewise-linear interpolation, clamped flat outside the point range.</summary>
    public static double Eval(IReadOnlyList<CurvePoint> pts, double x)
    {
        var p = (pts.Count == 0 ? IdentityPoints : pts).OrderBy(pt => pt.X).ToList();
        if (x <= p[0].X) return p[0].Y;
        if (x >= p[^1].X) return p[^1].Y;
        for (var i = 1; i < p.Count; i++)
        {
            if (x > p[i].X) continue;
            var a = p[i - 1];
            var b = p[i];
            var t = b.X - a.X == 0 ? 0 : (x - a.X) / (b.X - a.X);
            return a.Y + (b.Y - a.Y) * t;
        }
        return x;
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

    public static GradeCurve? FromJson(string json)
    {
        try
        {
            return PalmierJson.Decode<GradeCurve>(json);
        }
        catch
        {
            return null;
        }
    }
}
