namespace PalmierPro.Core.Analysis;

/// <summary>
/// Lightweight spectral noise gate for denoise bake when DeepFilter ONNX is absent.
/// Estimates a noise floor from quiet frames and attenuates bins below a threshold.
/// </summary>
public static class SpectralGateDenoiser
{
    public const int FftSize = 512;
    public const int Hop = 256;

    public static float[] Process(ReadOnlySpan<float> mono, double amount)
    {
        amount = Math.Clamp(amount, 0, 1);
        if (mono.IsEmpty || amount <= 0) return mono.ToArray();

        var n = mono.Length;
        var window = Hann(FftSize);
        var noisePower = EstimateNoisePower(mono, window);
        var output = new float[n];
        var overlap = new float[n + FftSize];
        var re = new float[FftSize];
        var im = new float[FftSize];

        for (var pos = 0; pos + FftSize <= n; pos += Hop)
        {
            for (var i = 0; i < FftSize; i++)
            {
                re[i] = mono[pos + i] * window[i];
                im[i] = 0;
            }
            Fft(re, im);
            for (var k = 0; k < FftSize; k++)
            {
                var power = re[k] * re[k] + im[k] * im[k];
                var floor = Math.Max(1e-12, noisePower[k]);
                var snr = power / floor;
                // Soft gate: more amount → stronger attenuation of low-SNR bins.
                var gain = snr / (snr + 1.0 + amount * 8.0);
                var g = (float)(1.0 - amount + amount * gain);
                re[k] *= g;
                im[k] *= g;
            }
            Ifft(re, im);
            for (var i = 0; i < FftSize; i++)
                overlap[pos + i] += re[i] * window[i];
        }

        // Normalize hop overlap-add.
        var scale = Hop / (float)FftSize * 2f;
        for (var i = 0; i < n; i++)
            output[i] = overlap[i] * scale;
        return output;
    }

    private static float[] EstimateNoisePower(ReadOnlySpan<float> mono, float[] window)
    {
        var accum = new double[FftSize];
        var frames = 0;
        var re = new float[FftSize];
        var im = new float[FftSize];
        var energies = new List<(int Pos, double E)>();
        for (var pos = 0; pos + FftSize <= mono.Length; pos += Hop)
        {
            double e = 0;
            for (var i = 0; i < FftSize; i++) e += mono[pos + i] * mono[pos + i];
            energies.Add((pos, e / FftSize));
        }
        if (energies.Count == 0) return new float[FftSize];
        var threshold = energies.OrderBy(x => x.E).ElementAt(Math.Max(0, energies.Count / 5)).E * 1.5;
        foreach (var (pos, e) in energies)
        {
            if (e > threshold) continue;
            for (var i = 0; i < FftSize; i++)
            {
                re[i] = mono[pos + i] * window[i];
                im[i] = 0;
            }
            Fft(re, im);
            for (var k = 0; k < FftSize; k++)
                accum[k] += re[k] * re[k] + im[k] * im[k];
            frames++;
        }
        var result = new float[FftSize];
        var denom = Math.Max(1, frames);
        for (var k = 0; k < FftSize; k++)
            result[k] = (float)(accum[k] / denom);
        return result;
    }

    private static float[] Hann(int n)
    {
        var w = new float[n];
        for (var i = 0; i < n; i++)
            w[i] = 0.5f * (1f - (float)Math.Cos(2 * Math.PI * i / (n - 1)));
        return w;
    }

    // In-place radix-2 Cooley–Tukey (n must be power of 2).
    private static void Fft(float[] re, float[] im)
    {
        var n = re.Length;
        for (int i = 1, j = 0; i < n; i++)
        {
            var bit = n >> 1;
            for (; (j & bit) != 0; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j)
            {
                (re[i], re[j]) = (re[j], re[i]);
                (im[i], im[j]) = (im[j], im[i]);
            }
        }
        for (var len = 2; len <= n; len <<= 1)
        {
            var ang = -2 * Math.PI / len;
            var wlenRe = (float)Math.Cos(ang);
            var wlenIm = (float)Math.Sin(ang);
            for (var i = 0; i < n; i += len)
            {
                float wRe = 1, wIm = 0;
                for (var j = 0; j < len / 2; j++)
                {
                    var uRe = re[i + j];
                    var uIm = im[i + j];
                    var vRe = re[i + j + len / 2] * wRe - im[i + j + len / 2] * wIm;
                    var vIm = re[i + j + len / 2] * wIm + im[i + j + len / 2] * wRe;
                    re[i + j] = uRe + vRe;
                    im[i + j] = uIm + vIm;
                    re[i + j + len / 2] = uRe - vRe;
                    im[i + j + len / 2] = uIm - vIm;
                    var nWRe = wRe * wlenRe - wIm * wlenIm;
                    wIm = wRe * wlenIm + wIm * wlenRe;
                    wRe = nWRe;
                }
            }
        }
    }

    private static void Ifft(float[] re, float[] im)
    {
        for (var i = 0; i < im.Length; i++) im[i] = -im[i];
        Fft(re, im);
        var inv = 1f / re.Length;
        for (var i = 0; i < re.Length; i++)
        {
            re[i] *= inv;
            im[i] = -im[i] * inv;
        }
    }
}
