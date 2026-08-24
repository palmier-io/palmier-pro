namespace PalmierPro.Core.Analysis;

/// <summary>Normalized cross-correlation offset between two mono PCM buffers.</summary>
public static class AudioSyncCorrelator
{
    public sealed record Result(double OffsetSeconds, double Confidence, string Method);

    public static Result Correlate(
        ReadOnlySpan<float> reference,
        ReadOnlySpan<float> target,
        int sampleRate,
        double searchWindowSeconds = 30)
    {
        if (reference.IsEmpty || target.IsEmpty || sampleRate <= 0)
            return new Result(0, 0, "none");

        // Downsample to ~1 kHz for speed.
        var hop = Math.Max(1, sampleRate / 1000);
        var a = Downsample(reference, hop);
        var b = Downsample(target, hop);
        var rate = sampleRate / (double)hop;
        var maxLag = (int)Math.Round(Math.Max(0.05, searchWindowSeconds) * rate);
        maxLag = Math.Min(maxLag, Math.Max(a.Length, b.Length));

        double best = double.NegativeInfinity;
        var bestLag = 0;
        for (var lag = -maxLag; lag <= maxLag; lag++)
        {
            var score = DotAtLag(a, b, lag);
            if (score > best)
            {
                best = score;
                bestLag = lag;
            }
        }

        var conf = Math.Clamp(best, 0, 1);
        return new Result(bestLag / rate, conf, "audio");
    }

    private static float[] Downsample(ReadOnlySpan<float> src, int hop)
    {
        var n = (src.Length + hop - 1) / hop;
        var dst = new float[n];
        for (var i = 0; i < n; i++)
        {
            var start = i * hop;
            var end = Math.Min(src.Length, start + hop);
            double sum = 0;
            for (var j = start; j < end; j++) sum += src[j];
            dst[i] = (float)(sum / Math.Max(1, end - start));
        }
        return dst;
    }

    private static double DotAtLag(float[] a, float[] b, int lag)
    {
        var i0 = Math.Max(0, lag);
        var j0 = Math.Max(0, -lag);
        var n = Math.Min(a.Length - i0, b.Length - j0);
        if (n <= 8) return double.NegativeInfinity;
        double dot = 0, na = 0, nb = 0;
        for (var k = 0; k < n; k++)
        {
            var x = a[i0 + k];
            var y = b[j0 + k];
            dot += x * y;
            na += x * x;
            nb += y * y;
        }
        if (na <= 1e-12 || nb <= 1e-12) return double.NegativeInfinity;
        return dot / Math.Sqrt(na * nb);
    }
}
