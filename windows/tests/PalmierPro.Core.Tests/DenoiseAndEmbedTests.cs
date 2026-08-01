using PalmierPro.Core.Analysis;
using PalmierPro.Core.Search;
using Xunit;

namespace PalmierPro.Core.Tests;

public class DenoiseAndEmbedTests
{
    [Fact]
    public void SpectralGateReducesNoiseFloorEnergy()
    {
        const int sr = 16000;
        var clean = new float[sr];
        var noisy = new float[sr];
        var rng = new Random(1);
        for (var i = 0; i < sr; i++)
        {
            clean[i] = (float)(0.2 * Math.Sin(2 * Math.PI * 440 * i / sr));
            noisy[i] = clean[i] + (float)((rng.NextDouble() - 0.5) * 0.15);
        }
        var wet = SpectralGateDenoiser.Process(noisy, amount: 0.8);
        Assert.Equal(noisy.Length, wet.Length);
        double noiseE = 0, wetE = 0;
        // Compare high-frequency residual on a quiet stretch of the first 256 samples after onset.
        for (var i = 8000; i < 9000; i++)
        {
            noiseE += noisy[i] * noisy[i];
            wetE += wet[i] * wet[i];
        }
        Assert.True(wetE < noiseE, $"expected wet energy {wetE} < noisy {noiseE}");
    }

    [Fact]
    public void FrameFeatureEmbedDiffersForDistinctColors()
    {
        var red = SolidBgra(32, 32, r: 255, g: 0, b: 0);
        var blue = SolidBgra(32, 32, r: 0, g: 0, b: 255);
        var a = EmbeddingMath.FrameFeatureEmbed(red, 32, 32, 32 * 4);
        var b = EmbeddingMath.FrameFeatureEmbed(blue, 32, 32, 32 * 4);
        Assert.True(EmbeddingMath.Cosine(a, b) < 0.95);
    }

    private static byte[] SolidBgra(int w, int h, byte r, byte g, byte b)
    {
        var data = new byte[w * h * 4];
        for (var i = 0; i < data.Length; i += 4)
        {
            data[i] = b;
            data[i + 1] = g;
            data[i + 2] = r;
            data[i + 3] = 255;
        }
        return data;
    }
}
