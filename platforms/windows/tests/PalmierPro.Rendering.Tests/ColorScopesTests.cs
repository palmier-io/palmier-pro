using System.Linq;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// E6: exercises PE_TimelineComputeColorScopes (native Scopes.h/.cpp + shaders/Scopes*.hlsl)
// against synthetic solid-color frames — docs/color-scopes-v1.md §2's bin-count/normalization
// contract, hand-computed the same way EffectKernelTests verifies GpuCompositor's other passes.
[Collection(MediaFixturesCollection.Name)]
public sealed class ColorScopesTests(MediaFixtures fixtures)
{
    private static string LoadTimelineSnapshotJson(string fixtureName, string fixtureDir) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", fixtureName))
            .Replace("{{FIXTURE_DIR}}", fixtureDir.Replace("\\", "\\\\"));

    private static int ArgMax(IReadOnlyList<float> values)
    {
        int best = 0;
        for (int i = 1; i < values.Count; i++)
        {
            if (values[i] > values[best])
            {
                best = i;
            }
        }
        return best;
    }

    [Fact]
    [Trait("Category", "Media")]
    public void SolidGray_YrgbHistogramsPeakTogetherNearMidGray()
    {
        using var session = new EngineSession();
        string json = LoadTimelineSnapshotJson("color-scopes-gray.snapshot.json", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));

        ColorScopesResult result = timeline.ComputeColorScopes(frame: 15);

        result.Frame.ShouldBe(15);
        result.YHistogram.Count.ShouldBe(ColorScopesResult.RgbBinCount);
        result.RHistogram.Count.ShouldBe(ColorScopesResult.RgbBinCount);
        result.GHistogram.Count.ShouldBe(ColorScopesResult.RgbBinCount);
        result.BHistogram.Count.ShouldBe(ColorScopesResult.RgbBinCount);
        result.HueHistogram.Count.ShouldBe(ColorScopesResult.HueBinCount);

        // A single spatially-uniform solid clip fills the whole downsampled grid, so each of
        // Y/R/G/B's own dominant bin IS the joint max (doc §2.1) — every peak normalizes to
        // exactly 1.0, regardless of which 8-bit value the YUV round-trip actually reconstructs.
        result.YHistogram.Max().ShouldBe(1.0f);
        result.RHistogram.Max().ShouldBe(1.0f);
        result.GHistogram.Max().ShouldBe(1.0f);
        result.BHistogram.Max().ShouldBe(1.0f);

        // Gray means R=G=B=Y numerically, so all four peaks should land in (nearly) the same
        // bin, near bin 128 (0x808080 = 128/255 -> floor(0.50196*256) = 128) — a generous ±32
        // window absorbs YUV 4:2:0 round-trip rounding without losing the hand-computed anchor.
        int yPeak = ArgMax(result.YHistogram);
        int rPeak = ArgMax(result.RHistogram);
        int gPeak = ArgMax(result.GHistogram);
        int bPeak = ArgMax(result.BHistogram);
        yPeak.ShouldBeInRange(96, 160, $"expected mid-gray's Y peak near bin 128, got {yPeak}");
        Math.Abs(yPeak - rPeak).ShouldBeLessThanOrEqualTo(2, "R should track Y for an achromatic source");
        Math.Abs(yPeak - gPeak).ShouldBeLessThanOrEqualTo(2, "G should track Y for an achromatic source");
        Math.Abs(yPeak - bPeak).ShouldBeLessThanOrEqualTo(2, "B should track Y for an achromatic source");
    }

    [Fact]
    [Trait("Category", "Media")]
    public void SolidGreen_HueHistogramPeaksAtGreenBin_RgChannelsSeparated()
    {
        using var session = new EngineSession();
        string json = LoadTimelineSnapshotJson("color-scopes-green.snapshot.json", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));

        ColorScopesResult result = timeline.ComputeColorScopes(frame: 15);

        // Pure green (r=0,g=1,b=0): mx=g, hue=(b-r)/d+2=2, hue/6=0.3333 -> bin=floor(0.3333*96)=32
        // (doc §2.2's hue formula, hand-computed). A single uniform region again means the hue
        // histogram's own peak normalizes to exactly 1.0 (max-then-sqrt of a single-bin signal).
        int huePeak = ArgMax(result.HueHistogram);
        huePeak.ShouldBeInRange(24, 40, $"expected green's hue peak near bin 32, got {huePeak}");
        result.HueHistogram.Max().ShouldBe(1.0f);

        // Channel-order sanity: green's R/B histograms should peak near 0, G's near 255 — catches
        // a channel-swap bug the hue check alone wouldn't (hue is symmetric-ish under some swaps).
        int rPeak = ArgMax(result.RHistogram);
        int gPeak = ArgMax(result.GHistogram);
        int bPeak = ArgMax(result.BHistogram);
        gPeak.ShouldBeGreaterThan(200, $"green channel should peak near 255, got bin {gPeak}");
        rPeak.ShouldBeLessThan(60, $"red channel should peak near 0 for a green source, got bin {rPeak}");
        bPeak.ShouldBeLessThan(60, $"blue channel should peak near 0 for a green source, got bin {bPeak}");
    }

    [Fact]
    [Trait("Category", "Media")]
    public void TwoToneComposite_JointNormalizesYrgbAcrossChannels()
    {
        // two-track.snapshot.json: a full-frame blue backdrop with a red clip covering exactly
        // the left half (centerX=0.25, width=0.5, height=1.0) — a clean 50/50 area split at the
        // canvas's midline (see EffectKernelTests' sibling fixtures for the same shape).
        using var session = new EngineSession();
        string json = LoadTimelineSnapshotJson("two-track.snapshot.json", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));

        ColorScopesResult result = timeline.ComputeColorScopes(frame: 15);

        float yMax = result.YHistogram.Max();
        float rMax = result.RHistogram.Max();
        float gMax = result.GHistogram.Max();
        float bMax = result.BHistogram.Max();

        // Red and blue both have G≈0 everywhere, so G's dominant bin covers the WHOLE grid and
        // becomes the joint max (doc §2.1's "one shared scalar across all four"). R/B/Y are each
        // dominated by only ONE half of the frame, so under CORRECT joint normalization their
        // peaks land around 0.5, well below G's ~1.0 — a per-channel-normalize bug would instead
        // pin every channel's own peak at 1.0, indistinguishable from G. This is exactly what
        // this test tells apart.
        gMax.ShouldBeGreaterThan(0.9f, $"G should be joint-max-dominant (~1.0), got {gMax}");
        rMax.ShouldBeInRange(0.30f, 0.70f, $"R should sit well below G's peak under joint normalization (got R={rMax}, G={gMax})");
        bMax.ShouldBeInRange(0.30f, 0.70f, $"B should sit well below G's peak under joint normalization (got B={bMax}, G={gMax})");
        yMax.ShouldBeInRange(0.30f, 0.70f, $"Y should sit well below G's peak under joint normalization (got Y={yMax}, G={gMax})");
    }
}
