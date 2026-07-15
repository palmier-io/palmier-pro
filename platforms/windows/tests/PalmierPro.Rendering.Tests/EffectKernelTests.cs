using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// E3: exercises the 11 ported Metal-kernel HLSL passes (GpuCompositor.cpp/shaders/*.hlsl)
// through the same synchronous PE_TimelineRenderFrameToFile golden hook TimelineCompositorTests
// already uses — deterministic, immune to scrub throttling. Fixtures under Fixtures/ carry a
// v1.1 "effects" array (docs/timeline-snapshot-v1.md §11).
[Collection(MediaFixturesCollection.Name)]
public sealed class EffectKernelTests(MediaFixtures fixtures)
{
    private static string LoadTimelineSnapshotJson(string fixtureName, string fixtureDir) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", fixtureName))
            .Replace("{{FIXTURE_DIR}}", fixtureDir.Replace("\\", "\\\\"));

    private static string RenderToTempPng(TimelineSession timeline, long frame)
    {
        string path = Path.Combine(Path.GetTempPath(), $"palmier-effect-{Guid.NewGuid():N}.png");
        timeline.RenderFrameToFile(frame, path);
        return path;
    }

    private static void AssertColorNear(Color actual, Color expected, int tolerance)
    {
        Math.Abs(actual.R - expected.R).ShouldBeLessThanOrEqualTo(tolerance, $"R: actual={actual} expected={expected}");
        Math.Abs(actual.G - expected.G).ShouldBeLessThanOrEqualTo(tolerance, $"G: actual={actual} expected={expected}");
        Math.Abs(actual.B - expected.B).ShouldBeLessThanOrEqualTo(tolerance, $"B: actual={actual} expected={expected}");
    }

    [Fact]
    [Trait("Category", "Media")]
    public void Levels_IdentityParams_IsPassthrough()
    {
        using var session = new EngineSession();
        string json = LoadTimelineSnapshotJson("levels-identity.snapshot.json", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));

        string pngPath = RenderToTempPng(timeline, frame: 15);
        try
        {
            using var bitmap = new Bitmap(pngPath);
            // Ingest (straight->premultiplied fp16) + an identity Levels pass should round-trip
            // the solid-red source to within 1 LSB of 8-bit rounding either side.
            AssertColorNear(bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2), Color.Red, tolerance: 2);
        }
        finally
        {
            File.Delete(pngPath);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void Vignette_DarkensCorners_NotCenter()
    {
        using var session = new EngineSession();
        string json = LoadTimelineSnapshotJson("vignette.snapshot.json", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));

        string pngPath = RenderToTempPng(timeline, frame: 15);
        try
        {
            using var bitmap = new Bitmap(pngPath);
            Color center = bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2);
            Color corner = bitmap.GetPixel(4, 4);

            // amount=-1, midpoint=0.2, feather=0.3: center stays near the source gray (128),
            // corners fall well outside midpoint+feather*1.5+0.05 -> v~1 -> rgb*(1+amount*1)=0.
            ((int)center.R).ShouldBeGreaterThan(100, "vignette must not darken the center");
            ((int)corner.R).ShouldBeLessThan(40, "vignette must darken the corners");
            ((int)corner.R).ShouldBeLessThan(center.R, "corner must be darker than center");
        }
        finally
        {
            File.Delete(pngPath);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void ChromaKey_KeysGreenFixtureToTransparent_RevealingBackdrop()
    {
        using var session = new EngineSession();
        string json = LoadTimelineSnapshotJson("chromakey-green.snapshot.json", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));

        string pngPath = RenderToTempPng(timeline, frame: 15);
        try
        {
            using var bitmap = new Bitmap(pngPath);
            // The top track's pure-green clip should key to (near-)transparent, letting the
            // bottom track's blue clip show through.
            AssertColorNear(bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2), Color.Blue, tolerance: 20);
        }
        finally
        {
            File.Delete(pngPath);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void Wheels_LiftAndGain_MatchHandComputedPixel()
    {
        using var session = new EngineSession();
        string json = LoadTimelineSnapshotJson("wheels.snapshot.json", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));

        string pngPath = RenderToTempPng(timeline, frame: 15);
        try
        {
            using var bitmap = new Bitmap(pngPath);
            // Neutral-chroma lift_m=0.2, gain_m=1.2, gamma_m=1 on a flat 0x808080 (128/255)
            // source: lit = max(0.5020*(1-0.2)+0.2, 0)*1.2 = 0.72188 -> 184.1/255.
            // Hand-computed from Wheels.hlsl/ColorWheels.h's exact formula.
            Color pixel = bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2);
            AssertColorNear(pixel, Color.FromArgb(184, 184, 184), tolerance: 4);
        }
        finally
        {
            File.Delete(pngPath);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void LutTetra_IdentityCube_ReproducesInputWithinOneLsb()
    {
        using var session = new EngineSession();
        string json = LoadTimelineSnapshotJson("luttetra-identity.snapshot.json", fixtures.FixturesDir)
            .Replace("{{LUT_PATH}}", fixtures.IdentityCubePath.Replace("\\", "\\\\"));
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));

        string pngPath = RenderToTempPng(timeline, frame: 15);
        try
        {
            using var bitmap = new Bitmap(pngPath);
            // Pure red (1,0,0) lands exactly on the identity cube's (1,0,0) corner — the
            // tetrahedral blend resolves to that corner's value exactly (see
            // CubeLutParser.h/LUTTetra.hlsl), so this should reproduce red within 8-bit rounding.
            AssertColorNear(bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2), Color.Red, tolerance: 2);
        }
        finally
        {
            File.Delete(pngPath);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void HueCurves_RedBandPush_RotatesRedLeavesBlueUntouched()
    {
        // Mirrors Tests/PalmierProTests/Rendering/HueCurvesTests.swift's `redBandRotatesRedLeavesBlue`.
        // A literal 180°-red-to-cyan rotation isn't reachable through this kernel: HueCurveKernel.swift's
        // maxHueShift caps a single hueVsHue push at ±30° (1/12 of a cycle), so this asserts the kernel's
        // actual, real behavior instead — a push on the red band visibly rotates red (G channel rises)
        // while an unrelated hue (blue, whose hue==0.6667 lands exactly on a neutral 0.5 control point in
        // this curve) is left within noise.
        using (var session = new EngineSession())
        {
            string json = LoadTimelineSnapshotJson("huecurves-redband-red.snapshot.json", fixtures.FixturesDir);
            using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));
            string pngPath = RenderToTempPng(timeline, frame: 15);
            try
            {
                using var bitmap = new Bitmap(pngPath);
                Color pixel = bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2);
                // Hand-computed: hue=0 pushed to 0.05 (dHue=(0.8-0.5)*2/12), sat/val unchanged (gate=1
                // at full saturation) -> HSV(0.05,1,1) -> RGB(1, 0.3, 0) (18° is 30% of the way from red
                // to yellow). G should rise well above 0, R stays near max, B stays near 0.
                ((int)pixel.R).ShouldBeGreaterThan(200, "red channel should stay near-max");
                ((int)pixel.G).ShouldBeGreaterThan(40, $"red should visibly rotate toward orange, got {pixel}");
                ((int)pixel.B).ShouldBeLessThan(20, $"no blue should appear, got {pixel}");
            }
            finally
            {
                File.Delete(pngPath);
            }
        }

        using (var session = new EngineSession())
        {
            string json = LoadTimelineSnapshotJson("huecurves-redband-blue.snapshot.json", fixtures.FixturesDir);
            using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));
            string pngPath = RenderToTempPng(timeline, frame: 15);
            try
            {
                using var bitmap = new Bitmap(pngPath);
                // Pure blue's hue (2/3) lands exactly on this curve's 4th control point (x=4/6, y=0.5,
                // i.e. neutral) -> zero shift -> blue must stay put, unaffected by the red-band push.
                AssertColorNear(bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2), Color.Blue, tolerance: 10);
            }
            finally
            {
                File.Delete(pngPath);
            }
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void Glow_ThresholdGating_BelowThresholdUnchanged_AboveThresholdBrightens()
    {
        // Flat 0x808080 (128/255=0.50196) gray source: for a spatially-uniform image the Gaussian
        // blur of the bright-pass output reproduces that same uniform value everywhere, so the whole
        // glowBright->blur->glowComposite chain collapses to hand-computable closed-form per-channel
        // math (see GlowBright.hlsl / GlowComposite.hlsl).
        string LoadWithThreshold(double threshold) =>
            File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "glow-threshold-template.snapshot.json"))
                .Replace("{{FIXTURE_DIR}}", fixtures.FixturesDir.Replace("\\", "\\\\"))
                .Replace("__THRESHOLD__", threshold.ToString(System.Globalization.CultureInfo.InvariantCulture));

        // threshold=0.8 > y(0.502): smoothstep clamps to 0 below the lower edge -> zero glow contribution
        // -> screen-composite of source with black glow is the identity -> unchanged.
        using (var session = new EngineSession())
        {
            string json = LoadWithThreshold(0.8);
            using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));
            string pngPath = RenderToTempPng(timeline, frame: 15);
            try
            {
                using var bitmap = new Bitmap(pngPath);
                AssertColorNear(bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2), Color.FromArgb(128, 128, 128), tolerance: 4);
            }
            finally
            {
                File.Delete(pngPath);
            }
        }

        // threshold=0.3 < y(0.502): hi = y*smoothstep(0.3,1,0.502) = 0.502*0.201803 = 0.101305 (per
        // channel, warmth=0). Uniform blur reproduces that value; screen-compose with intensity=1:
        // 1-(1-0.502)(1-0.101305) = 0.552466 -> ~141/255, well above the unmodified 128.
        using (var session = new EngineSession())
        {
            string json = LoadWithThreshold(0.3);
            using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));
            string pngPath = RenderToTempPng(timeline, frame: 15);
            try
            {
                using var bitmap = new Bitmap(pngPath);
                Color pixel = bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2);
                ((int)pixel.R).ShouldBeGreaterThan(133, $"above-threshold glow must brighten the frame, got {pixel}");
                AssertColorNear(pixel, Color.FromArgb(141, 141, 141), tolerance: 8);
            }
            finally
            {
                File.Delete(pngPath);
            }
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void HighlightsShadows_HighlightsBoost_MatchesHandComputedPixel()
    {
        using var session = new EngineSession();
        string json = LoadTimelineSnapshotJson("highlights-shadows.snapshot.json", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));

        string pngPath = RenderToTempPng(timeline, frame: 15);
        try
        {
            using var bitmap = new Bitmap(pngPath);
            // Gray 0x808080 (y=0.501961): hi=y^3=0.126476, dY=highlights*hi*0.5=0.063238 (shadows=0)
            // -> 0.501961+0.063238=0.565199*255=144.1.
            AssertColorNear(bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2), Color.FromArgb(144, 144, 144), tolerance: 6);
        }
        finally
        {
            File.Delete(pngPath);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void GradeCurves_MasterMidtoneLift_MatchesHandComputedPixel()
    {
        using var session = new EngineSession();
        string json = LoadTimelineSnapshotJson("gradecurves-master-lift.snapshot.json", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));

        string pngPath = RenderToTempPng(timeline, frame: 15);
        try
        {
            using var bitmap = new Bitmap(pngPath);
            // master curve (0,0)-(0.5,0.7)-(1,1); y=0.501961 falls just past the midpoint:
            // t=(0.501961-0.5)/0.5=0.003922, yp=0.7+0.3*t=0.701176. Luma-preserving rescale on a flat
            // gray reproduces yp exactly per channel (rgb*yp/y == yp when r=g=b=y); red/green/blue
            // per-channel curves are empty (identity) so that's also the final value: 0.701176*255=178.8.
            AssertColorNear(bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2), Color.FromArgb(179, 179, 179), tolerance: 8);
        }
        finally
        {
            File.Delete(pngPath);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void Clarity_FlatSource_ClarityIsNoOp_DehazePivotsAroundAnchor()
    {
        // On a spatially-flat source, blurred == source everywhere, so Clarity's local-contrast term
        // (source-blurred)*clarity is exactly zero regardless of `clarity` — only `dehaze`'s
        // contrast-pivot-around-0.45 step (which doesn't depend on local contrast) can move the pixel.
        using (var session = new EngineSession())
        {
            string json = LoadTimelineSnapshotJson("clarity-flat-noop.snapshot.json", fixtures.FixturesDir);
            using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));
            string pngPath = RenderToTempPng(timeline, frame: 15);
            try
            {
                using var bitmap = new Bitmap(pngPath);
                AssertColorNear(bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2), Color.FromArgb(128, 128, 128), tolerance: 3);
            }
            finally
            {
                File.Delete(pngPath);
            }
        }

        string LoadWithDehaze(double dehaze) =>
            File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "clarity-dehaze-template.snapshot.json"))
                .Replace("{{FIXTURE_DIR}}", fixtures.FixturesDir.Replace("\\", "\\\\"))
                .Replace("__DEHAZE__", dehaze.ToString(System.Globalization.CultureInfo.InvariantCulture));

        // dark=y=0.501961 >= 0.5 -> smoothstep(0.05,0.5,dark) saturates to 1 -> w=dehaze*1.0.
        // Local-contrast term is 0 (flat source); pivot: 0.45+(0.501961-0.45)*(1+0.45*w).
        // dehaze=1 -> w=1 -> 0.45+0.051961*1.45=0.525343 -> 134.
        using (var session = new EngineSession())
        {
            string json = LoadWithDehaze(1.0);
            using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));
            string pngPath = RenderToTempPng(timeline, frame: 15);
            try
            {
                using var bitmap = new Bitmap(pngPath);
                AssertColorNear(bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2), Color.FromArgb(134, 134, 134), tolerance: 6);
            }
            finally
            {
                File.Delete(pngPath);
            }
        }

        // dehaze=-1 -> w=-1 -> 0.45+0.051961*0.55=0.478579 -> 122.
        using (var session = new EngineSession())
        {
            string json = LoadWithDehaze(-1.0);
            using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));
            string pngPath = RenderToTempPng(timeline, frame: 15);
            try
            {
                using var bitmap = new Bitmap(pngPath);
                AssertColorNear(bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2), Color.FromArgb(122, 122, 122), tolerance: 6);
            }
            finally
            {
                File.Delete(pngPath);
            }
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void Grain_Amount1_AddsPerPixelVarianceAcrossTheFrame()
    {
        // Hash-seeded per-pixel noise isn't hand-computable pixel-by-pixel without reimplementing
        // Hash13 bit-for-bit; mirrors GrainKernelTests.swift's `addsNoise` instead — assert the
        // rendered frame gains real per-pixel variance versus its flat 128 source, sampled over a
        // grid (single-pixel sampling would be flaky: hash13 could coincidentally land near zero at
        // any one point).
        using var session = new EngineSession();
        string json = LoadTimelineSnapshotJson("grain-amount1.snapshot.json", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));

        string pngPath = RenderToTempPng(timeline, frame: 15);
        try
        {
            using var bitmap = new Bitmap(pngPath);
            var samples = new List<int>();
            for (int y = 10; y < bitmap.Height; y += 23)
            {
                for (int x = 10; x < bitmap.Width; x += 29)
                {
                    samples.Add(bitmap.GetPixel(x, y).R);
                }
            }
            samples.Count.ShouldBeGreaterThan(50, "grid should yield enough samples to avoid flakiness");
            double mean = samples.Average();
            double variance = samples.Average(v => (v - mean) * (v - mean));
            variance.ShouldBeGreaterThan(4.0, $"grain must add visible per-pixel variance, got variance={variance} mean={mean}");
            // Grain is luma-masked and bounded (delta = n*amount*0.35*lumaMask, n in [-0.5,0.5)) — the
            // mean should still sit close to the flat source's 128, not drift the whole frame.
            Math.Abs(mean - 128).ShouldBeLessThanOrEqualTo(15, $"grain should not bias the mean brightness, got mean={mean}");
        }
        finally
        {
            File.Delete(pngPath);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void KeyframedOpacity_AtMidpointFrame_MatchesLinearLerp()
    {
        using var session = new EngineSession();
        string json = LoadTimelineSnapshotJson("keyframed-opacity.snapshot.json", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));

        // Opacity keyframes 0->0.0, 60->1.0 (linear); at frame 30 (clip-relative, since
        // startFrame=0) t=0.5 -> opacity=0.5 -> same expected pixel as
        // TimelineCompositorTests.OpacityHalf_BlendsRedOverBlue (static opacity=0.5): the
        // SourceOverAccumulate math premultiplies by the source's OWN alpha (1), fades ONLY the
        // alpha channel by clip opacity -> red channel stays full-strength, blue shows through
        // at 50% coverage.
        string pngPath = RenderToTempPng(timeline, frame: 30);
        try
        {
            using var bitmap = new Bitmap(pngPath);
            AssertColorNear(bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2), Color.FromArgb(255, 0, 128), tolerance: 10);
        }
        finally
        {
            File.Delete(pngPath);
        }

        // Boundary check: at frame 0 opacity should be ~0 (backdrop only, pure blue); this
        // isolates "keyframes evaluate per-frame" from "the composite math at 0.5 happens to
        // look right regardless."
        string pngPathStart = RenderToTempPng(timeline, frame: 0);
        try
        {
            using var bitmap = new Bitmap(pngPathStart);
            AssertColorNear(bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2), Color.Blue, tolerance: 12);
        }
        finally
        {
            File.Delete(pngPathStart);
        }
    }
}
