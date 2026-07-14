using System.Text.Json;
using System.Text.Json.Serialization;

namespace PalmierPro.Core.Models;

/// Plain Codable in Swift, no custom init: both fields required on decode (see Crop/WordTiming for
/// the same pattern). Value-equatable so <see cref="GradeCurve.IsIdentity"/>'s array comparison
/// mirrors Swift's synthesized `Equatable`.
public sealed class CurvePoint : IEquatable<CurvePoint>
{
    [JsonPropertyName("x")]
    [JsonRequired]
    public double X { get; set; }

    [JsonPropertyName("y")]
    [JsonRequired]
    public double Y { get; set; }

    public CurvePoint()
    {
    }

    public CurvePoint(double x, double y)
    {
        X = x;
        Y = y;
    }

    public bool Equals(CurvePoint? other) => other is not null && X.Equals(other.X) && Y.Equals(other.Y);
    public override bool Equals(object? obj) => Equals(obj as CurvePoint);
    public override int GetHashCode() => HashCode.Combine(X, Y);
}

/// Master (Rec.709 luma) + per-channel R/G/B tone curves, compiled to a 3D LUT at render time.
/// Plain Codable in Swift, no custom init: all four fields required on decode.
public sealed class GradeCurve
{
    [JsonPropertyName("master")]
    [JsonRequired]
    public List<CurvePoint> Master { get; set; } = [];

    [JsonPropertyName("red")]
    [JsonRequired]
    public List<CurvePoint> Red { get; set; } = [];

    [JsonPropertyName("green")]
    [JsonRequired]
    public List<CurvePoint> Green { get; set; } = [];

    [JsonPropertyName("blue")]
    [JsonRequired]
    public List<CurvePoint> Blue { get; set; } = [];

    public static readonly IReadOnlyList<CurvePoint> IdentityPoints = [new CurvePoint(0, 0), new CurvePoint(1, 1)];

    [JsonIgnore]
    public bool IsIdentity =>
        new[] { Master, Red, Green, Blue }.All(pts => pts.Count == 0 || pts.SequenceEqual(IdentityPoints));

    /// Piecewise-linear interpolation, clamped flat outside the point range.
    public static double Eval(IReadOnlyList<CurvePoint> pts, double x)
    {
        var p = (pts.Count == 0 ? IdentityPoints : pts).OrderBy(pt => pt.X).ToList();
        if (x <= p[0].X)
        {
            return p[0].Y;
        }
        if (x >= p[^1].X)
        {
            return p[^1].Y;
        }
        for (var i = 1; i < p.Count; i++)
        {
            if (x <= p[i].X)
            {
                var a = p[i - 1];
                var b = p[i];
                var t = b.X - a.X == 0 ? 0 : (x - a.X) / (b.X - a.X);
                return a.Y + (b.Y - a.Y) * t;
            }
        }
        return x;
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

    public static GradeCurve? FromJson(string json)
    {
        try
        {
            return JsonSerializer.Deserialize<GradeCurve>(json);
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
