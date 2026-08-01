namespace PalmierPro.Core.Search;

public static class EmbeddingMath
{
    public static float Cosine(ReadOnlySpan<float> a, ReadOnlySpan<float> b)
    {
        if (a.Length == 0 || a.Length != b.Length) return 0;
        double dot = 0, na = 0, nb = 0;
        for (var i = 0; i < a.Length; i++)
        {
            dot += a[i] * b[i];
            na += a[i] * a[i];
            nb += b[i] * b[i];
        }
        if (na <= 0 || nb <= 0) return 0;
        return (float)(dot / (Math.Sqrt(na) * Math.Sqrt(nb)));
    }

    /// <summary>Deterministic bag-of-chars embedding for scaffold text / spoken search.</summary>
    public static float[] TextEmbed(string text, int dims = 64)
    {
        var v = new float[dims];
        if (string.IsNullOrWhiteSpace(text)) return v;
        foreach (var ch in text.ToLowerInvariant())
        {
            if (ch is < 'a' or > 'z' && ch is not (' ' or '\'')) continue;
            var i = ch % dims;
            v[i] += 1f;
        }
        // L2 normalize
        double n = 0;
        for (var i = 0; i < dims; i++) n += v[i] * v[i];
        if (n <= 0) return v;
        var inv = (float)(1.0 / Math.Sqrt(n));
        for (var i = 0; i < dims; i++) v[i] *= inv;
        return v;
    }

    /// <summary>
    /// Visual-ish embedding from file bytes: samples evenly spaced RGB triplets into a
    /// spatial grid (not bag-of-bytes). Prefer <see cref="FrameFeatureEmbed"/> when BGRA is available.
    /// </summary>
    public static float[] SampledFileVisualEmbed(ReadOnlySpan<byte> bytes, int dims = 64)
    {
        if (bytes.IsEmpty) return new float[dims];
        // Skip small container headers; treat remaining as a synthetic raster.
        var start = Math.Min(bytes.Length, 512);
        var payload = bytes[start..];
        if (payload.Length < 12) return BytesEmbed(bytes, dims);
        var pixels = payload.Length / 3;
        var side = Math.Max(8, (int)Math.Sqrt(pixels));
        var bgra = new byte[side * side * 4];
        for (var i = 0; i < side * side; i++)
        {
            var src = (i * 3) % (payload.Length - 2);
            bgra[i * 4] = payload[src + 2];
            bgra[i * 4 + 1] = payload[src + 1];
            bgra[i * 4 + 2] = payload[src];
            bgra[i * 4 + 3] = 255;
        }
        return FrameFeatureEmbed(bgra, side, side, side * 4, dims);
    }

    /// <summary>Content fingerprint embedding from raw file bytes (legacy scaffold).</summary>
    public static float[] BytesEmbed(ReadOnlySpan<byte> bytes, int dims = 64)
    {
        var v = new float[dims];
        if (bytes.IsEmpty) return v;
        var step = Math.Max(1, bytes.Length / 4096);
        for (var i = 0; i < bytes.Length; i += step)
            v[bytes[i] % dims] += 1f;
        return L2Normalize(v);
    }

    /// <summary>
    /// Visual feature from a BGRA frame sample (color + coarse spatial histogram).
    /// Replaces bag-of-bytes until SigLIP ONNX is bundled.
    /// </summary>
    public static float[] FrameFeatureEmbed(ReadOnlySpan<byte> bgra, int width, int height, int stride, int dims = 64)
    {
        var v = new float[dims];
        if (bgra.IsEmpty || width <= 0 || height <= 0) return v;
        var grid = 4;
        var binsPerCell = Math.Max(1, dims / (grid * grid));
        for (var gy = 0; gy < grid; gy++)
        for (var gx = 0; gx < grid; gx++)
        {
            var x0 = gx * width / grid;
            var x1 = (gx + 1) * width / grid;
            var y0 = gy * height / grid;
            var y1 = (gy + 1) * height / grid;
            double rSum = 0, gSum = 0, bSum = 0, edge = 0;
            var count = 0;
            byte prev = 0;
            for (var y = y0; y < y1; y++)
            {
                var row = y * stride;
                for (var x = x0; x < x1; x++)
                {
                    var i = row + x * 4;
                    if (i + 3 >= bgra.Length) continue;
                    var b = bgra[i];
                    var g = bgra[i + 1];
                    var r = bgra[i + 2];
                    rSum += r; gSum += g; bSum += b;
                    edge += Math.Abs(r - prev);
                    prev = r;
                    count++;
                }
            }
            if (count == 0) continue;
            var baseIdx = (gy * grid + gx) * binsPerCell;
            if (baseIdx < dims) v[baseIdx] += (float)(rSum / count / 255.0);
            if (baseIdx + 1 < dims) v[baseIdx + 1] += (float)(gSum / count / 255.0);
            if (baseIdx + 2 < dims) v[baseIdx + 2] += (float)(bSum / count / 255.0);
            if (baseIdx + 3 < dims) v[baseIdx + 3] += (float)Math.Min(1.0, edge / count / 64.0);
        }
        return L2Normalize(v);
    }

    private static float[] L2Normalize(float[] v)
    {
        double n = 0;
        for (var i = 0; i < v.Length; i++) n += v[i] * v[i];
        if (n <= 0) return v;
        var inv = (float)(1.0 / Math.Sqrt(n));
        for (var i = 0; i < v.Length; i++) v[i] *= inv;
        return v;
    }
}
