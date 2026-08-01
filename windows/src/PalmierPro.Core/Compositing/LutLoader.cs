namespace PalmierPro.Core.Compositing;

/// <summary>Parsed .cube 3D LUT packed as RGBA float32 with R fastest (CIColorCube layout).</summary>
public sealed record CubeLut(int Dimension, float[] Rgba);

/// <summary>Parses Adobe .cube 3D LUTs. Shared by preview, export, and Agent apply_color.</summary>
public static class LutLoader
{
    private static readonly object Lock = new();
    private static readonly Dictionary<string, CubeLut> Cache = [];

    public static CubeLut? Load(string path)
    {
        lock (Lock)
        {
            if (Cache.TryGetValue(path, out var cached)) return cached;
        }
        if (!File.Exists(path)) return null;
        string text;
        try { text = File.ReadAllText(path); }
        catch { return null; }
        if (Parse(text) is not { } lut) return null;
        lock (Lock)
        {
            Cache[path] = lut;
            return lut;
        }
    }

    public static CubeLut? Parse(string text)
    {
        var dimension = 0;
        var domainMin = new float[] { 0, 0, 0 };
        var domainMax = new float[] { 1, 1, 1 };
        var values = new List<float>();

        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 0) continue;
            switch (parts[0].ToUpperInvariant())
            {
                case "TITLE":
                    break;
                case "LUT_1D_SIZE":
                    return null;
                case "LUT_3D_SIZE":
                    dimension = int.TryParse(parts[^1], out var d) ? d : 0;
                    break;
                case "DOMAIN_MIN":
                    domainMin = parts.Skip(1).Select(float.Parse).ToArray();
                    break;
                case "DOMAIN_MAX":
                    domainMax = parts.Skip(1).Select(float.Parse).ToArray();
                    break;
                default:
                    if (parts.Length < 3) continue;
                    if (!float.TryParse(parts[0], out var r)
                        || !float.TryParse(parts[1], out var g)
                        || !float.TryParse(parts[2], out var b))
                        return null;
                    values.Add(r); values.Add(g); values.Add(b);
                    break;
            }
        }

        if (dimension is <= 1 or > 128
            || values.Count != dimension * dimension * dimension * 3
            || domainMin.Length != 3 || domainMax.Length != 3)
            return null;

        var rgba = new float[dimension * dimension * dimension * 4];
        for (var i = 0; i < values.Count / 3; i++)
        {
            for (var c = 0; c < 3; c++)
            {
                var span = Math.Max(0.0001f, domainMax[c] - domainMin[c]);
                rgba[i * 4 + c] = Math.Clamp((values[i * 3 + c] - domainMin[c]) / span, 0, 1);
            }
            rgba[i * 4 + 3] = 1;
        }
        return new CubeLut(dimension, rgba);
    }

    /// <summary>Tetrahedral 3D LUT sample. Port of Metal/LUTTetra.metal.</summary>
    public static (float R, float G, float B) SampleTetra(CubeLut lut, float r, float g, float b, float intensity)
    {
        if (intensity <= 0) return (r, g, b);
        var n = (float)lut.Dimension;
        var pR = Math.Clamp(r, 0, 1) * (n - 1);
        var pG = Math.Clamp(g, 0, 1) * (n - 1);
        var pB = Math.Clamp(b, 0, 1) * (n - 1);
        var b0r = Math.Clamp(MathF.Floor(pR), 0, n - 2);
        var b0g = Math.Clamp(MathF.Floor(pG), 0, n - 2);
        var b0b = Math.Clamp(MathF.Floor(pB), 0, n - 2);
        var fr = pR - b0r;
        var fg = pG - b0g;
        var fb = pB - b0b;

        var c000 = Fetch(lut, b0r, b0g, b0b);
        var c111 = Fetch(lut, b0r + 1, b0g + 1, b0b + 1);
        (float R, float G, float B) o;
        if (fr >= fg)
        {
            if (fg >= fb)
                o = Mix4(c000, Fetch(lut, b0r + 1, b0g, b0b), Fetch(lut, b0r + 1, b0g + 1, b0b), c111,
                    1 - fr, fr - fg, fg - fb, fb);
            else if (fr >= fb)
                o = Mix4(c000, Fetch(lut, b0r + 1, b0g, b0b), Fetch(lut, b0r + 1, b0g, b0b + 1), c111,
                    1 - fr, fr - fb, fb - fg, fg);
            else
                o = Mix4(c000, Fetch(lut, b0r, b0g, b0b + 1), Fetch(lut, b0r + 1, b0g, b0b + 1), c111,
                    1 - fb, fb - fr, fr - fg, fg);
        }
        else
        {
            if (fb >= fg)
                o = Mix4(c000, Fetch(lut, b0r, b0g, b0b + 1), Fetch(lut, b0r, b0g + 1, b0b + 1), c111,
                    1 - fb, fb - fg, fg - fr, fr);
            else if (fb >= fr)
                o = Mix4(c000, Fetch(lut, b0r, b0g + 1, b0b), Fetch(lut, b0r, b0g + 1, b0b + 1), c111,
                    1 - fg, fg - fb, fb - fr, fr);
            else
                o = Mix4(c000, Fetch(lut, b0r, b0g + 1, b0b), Fetch(lut, b0r + 1, b0g + 1, b0b), c111,
                    1 - fg, fg - fr, fr - fb, fb);
        }

        return (
            r + (o.R - r) * intensity,
            g + (o.G - g) * intensity,
            b + (o.B - b) * intensity);
    }

    private static (float R, float G, float B) Fetch(CubeLut lut, float ir, float ig, float ib)
    {
        var n = lut.Dimension;
        var r = (int)ir;
        var g = (int)ig;
        var b = (int)ib;
        var index = ((b * n + g) * n + r) * 4;
        return (lut.Rgba[index], lut.Rgba[index + 1], lut.Rgba[index + 2]);
    }

    private static (float R, float G, float B) Mix4(
        (float R, float G, float B) a, (float R, float G, float B) b,
        (float R, float G, float B) c, (float R, float G, float B) d,
        float wa, float wb, float wc, float wd)
        => (
            a.R * wa + b.R * wb + c.R * wc + d.R * wd,
            a.G * wa + b.G * wb + c.G * wc + d.G * wd,
            a.B * wa + b.B * wb + c.B * wc + d.B * wd);
}
