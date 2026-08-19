using PalmierPro.Core.Compositing;
using PalmierPro.Core.Models;
using Xunit;

namespace PalmierPro.Core.Tests;

public class EffectKernelTests
{
    [Fact]
    public void LevelsMatchesMetalFormula()
    {
        var (r, g, b) = EffectPixelKernels.Levels(0.5f, 0.5f, 0.5f, blacks: 0.5f, whites: 0f);
        // bp = -0.2, wp = 1, denom = 1.2 → (0.5+0.2)/1.2 = 0.5833…
        Assert.Equal(0.5833333f, r, 4);
        Assert.Equal(r, g);
        Assert.Equal(r, b);
    }

    [Fact]
    public void LevelsIdentityWhenNeutral()
    {
        var (r, g, b) = EffectPixelKernels.Levels(0.25f, 0.5f, 0.75f, 0, 0);
        Assert.Equal(0.25f, r);
        Assert.Equal(0.5f, g);
        Assert.Equal(0.75f, b);
    }

    [Fact]
    public void HighlightsShadowsPeaksAtWhiteAndBlack()
    {
        // White: hi=1, lo=0 → +highlights*0.5
        var (wr, _, _) = EffectPixelKernels.HighlightsShadows(1, 1, 1, highlights: 1, shadows: 0);
        Assert.Equal(1f, wr); // saturates
        // Black: hi=0, lo=1 → +shadows*0.5
        var (br, _, _) = EffectPixelKernels.HighlightsShadows(0, 0, 0, highlights: 0, shadows: 1);
        Assert.Equal(0.5f, br, 4);
    }

    [Fact]
    public void ExposureDoublesPerStop()
    {
        var (r, _, _) = EffectPixelKernels.Exposure(0.25f, 0.25f, 0.25f, 1f);
        Assert.Equal(0.5f, r, 4);
    }

    [Fact]
    public void ContrastPivotsAroundHalf()
    {
        var (mid, _, _) = EffectPixelKernels.Contrast(0.5f, 0.5f, 0.5f, 2f);
        Assert.Equal(0.5f, mid, 4);
        var (hi, _, _) = EffectPixelKernels.Contrast(0.75f, 0.75f, 0.75f, 2f);
        Assert.Equal(1f, hi, 4);
    }

    [Fact]
    public void ChromaKeyRemovesSaturatedGreen()
    {
        // Pure green ≈ hue 0.333, high sat.
        var (_, _, _, a) = EffectPixelKernels.ChromaKey(
            0f, 1f, 0f, 1f, keyHue: 0.333f, tolerance: 1f, softness: 0.1f, spill: 0.5f);
        Assert.True(a < 0.1f);

        // Neutral gray should survive.
        var (_, _, _, ga) = EffectPixelKernels.ChromaKey(
            0.5f, 0.5f, 0.5f, 1f, keyHue: 0.333f, tolerance: 1f, softness: 0.1f, spill: 0.5f);
        Assert.Equal(1f, ga, 3);
    }

    [Fact]
    public void VignetteDarkensCorners()
    {
        var (centerR, _, _) = EffectPixelKernels.Vignette(
            1, 1, 1, px: 50, py: 50, width: 100, height: 100,
            amount: -1, midpoint: 0.5f, roundness: 1, feather: 0.5f);
        var (cornerR, _, _) = EffectPixelKernels.Vignette(
            1, 1, 1, px: 0, py: 0, width: 100, height: 100,
            amount: -1, midpoint: 0.5f, roundness: 1, feather: 0.5f);
        Assert.True(cornerR < centerR);
    }

    [Fact]
    public void EdgeRoundingZeroAtOutsideCorner()
    {
        var coverage = EffectPixelKernels.EdgeRoundingCoverage(
            0, 0, 100, 100, edgeRounding: 1, edgeSoftness: 0);
        Assert.True(coverage < 0.5f);
        var center = EffectPixelKernels.EdgeRoundingCoverage(
            50, 50, 100, 100, edgeRounding: 1, edgeSoftness: 0);
        Assert.Equal(1f, center, 3);
    }

    [Fact]
    public void GrainIsDeterministicAndMidtoneBiased()
    {
        var (a1, _, _) = EffectPixelKernels.Grain(0.5f, 0.5f, 0.5f, 10, 20, 1f, 1.5f, 0);
        var (a2, _, _) = EffectPixelKernels.Grain(0.5f, 0.5f, 0.5f, 10, 20, 1f, 1.5f, 0);
        Assert.Equal(a1, a2);
        // Mid-gray should move; pure black should barely move (lumaMask≈0).
        var (black, _, _) = EffectPixelKernels.Grain(0f, 0f, 0f, 10, 20, 1f, 1.5f, 0);
        Assert.Equal(0f, black, 3);
        Assert.NotEqual(0.5f, a1);
    }

    [Fact]
    public void WheelsNeutralIsIdentity()
    {
        var p = new ResolvedEffectParams
        {
            Values = new Dictionary<string, double>
            {
                ["lift_x"] = 0, ["lift_y"] = 0, ["lift_m"] = 0,
                ["gamma_x"] = 0, ["gamma_y"] = 0, ["gamma_m"] = 1,
                ["gain_x"] = 0, ["gain_y"] = 0, ["gain_m"] = 1,
            },
            Strings = [],
        };
        Assert.True(ColorWheels.IsNeutral(p));
        var c = ColorWheels.CoefficientsFor(p);
        var (r, g, b) = EffectPixelKernels.Wheels(0.4f, 0.5f, 0.6f, c);
        Assert.Equal(0.4f, r, 3);
        Assert.Equal(0.5f, g, 3);
        Assert.Equal(0.6f, b, 3);
    }

    [Fact]
    public void RegistryResolvesAndClampsParams()
    {
        var descriptor = EffectRegistry.Descriptor("color.exposure")!;
        var effect = descriptor.MakeEffect();
        effect.Params["ev"] = new EffectParam { Value = 99 };
        var resolved = descriptor.Resolve(effect, 0);
        Assert.Equal(3, resolved.Value("ev")); // clamped to max
    }

    [Fact]
    public void InsertIndexFollowsCanonicalOrder()
    {
        var effects = new List<Effect>
        {
            Effect.Make("color.saturation"),
            Effect.Make("stylize.grain"),
        };
        var index = EffectRegistry.InsertIndex(effects, "color.exposure");
        Assert.Equal(0, index);
        Assert.Equal(1, EffectRegistry.InsertIndex(effects, "blur.gaussian"));
    }

    [Fact]
    public void MultiplyBlendDarkens()
    {
        var (r, g, b) = BlendModes.Blend(BlendMode.Multiply, 0.5f, 0.5f, 0.5f, 0.8f, 0.8f, 0.8f);
        Assert.Equal(0.4f, r, 4);
        Assert.Equal(r, g);
        Assert.Equal(r, b);
    }

    [Fact]
    public void ScreenBlendLightens()
    {
        var (r, _, _) = BlendModes.Blend(BlendMode.Screen, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f);
        Assert.Equal(0.75f, r, 4);
    }

    [Fact]
    public void HistogramCountsChannels()
    {
        // 2×1: pure red, pure blue
        var bgra = new byte[]
        {
            0, 0, 255, 255,
            255, 0, 0, 255,
        };
        var hist = ColorScopes.ComputeHistogram(bgra, 2, 1, 8);
        Assert.Equal(1, hist.Red[255]);
        Assert.Equal(1, hist.Blue[255]);
        Assert.Equal(2, hist.SampleCount);
    }

    [Fact]
    public void WaveformPutsWhiteAtTop()
    {
        var bgra = new byte[] { 255, 255, 255, 255 }; // white
        var wave = ColorScopes.ComputeWaveform(bgra, 1, 1, 4, outputWidth: 1);
        Assert.Equal(1f, wave.Densities[255 * 1 + 0], 3);
        Assert.Equal(0f, wave.Densities[0], 3);
    }

    [Fact]
    public void LutParseRejectsOneDimensional()
    {
        Assert.Null(LutLoader.Parse("LUT_1D_SIZE 2\n0 0 0\n1 1 1\n"));
    }

    [Fact]
    public void IdentityLutTetraIsPassthrough()
    {
        // 2³ identity cube: node (r,g,b) → (r/(n-1), g/(n-1), b/(n-1))
        var n = 2;
        var rgba = new float[n * n * n * 4];
        for (var b = 0; b < n; b++)
        for (var g = 0; g < n; g++)
        for (var r = 0; r < n; r++)
        {
            var i = ((b * n + g) * n + r) * 4;
            rgba[i] = r / (float)(n - 1);
            rgba[i + 1] = g / (float)(n - 1);
            rgba[i + 2] = b / (float)(n - 1);
            rgba[i + 3] = 1;
        }
        var lut = new CubeLut(n, rgba);
        var (or, og, ob) = LutLoader.SampleTetra(lut, 0.25f, 0.5f, 0.75f, intensity: 1);
        Assert.Equal(0.25f, or, 3);
        Assert.Equal(0.5f, og, 3);
        Assert.Equal(0.75f, ob, 3);
    }

    [Fact]
    public void LutParseReadsMinimalCube()
    {
        var text = """
            LUT_3D_SIZE 2
            0 0 0
            1 0 0
            0 1 0
            1 1 0
            0 0 1
            1 0 1
            0 1 1
            1 1 1
            """;
        var lut = LutLoader.Parse(text);
        Assert.NotNull(lut);
        Assert.Equal(2, lut.Dimension);
        Assert.Equal(2 * 2 * 2 * 4, lut.Rgba.Length);
    }
}
