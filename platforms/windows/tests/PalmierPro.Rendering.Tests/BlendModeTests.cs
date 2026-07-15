using System.Drawing;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// E3: exercises Composite.hlsl's PDF (ISO 32000-1) blend-mode dispatch — both a separable pair
// (multiply/screen, hand-computed) and a non-separable mode (hue) sanity check. Top track: pure
// red (1,0,0), full opacity, the blend mode under test. Bottom track: pure blue (0,0,1), opaque,
// "normal". Both fixtures/values chosen so the PDF composite formula collapses to something
// hand-computable (opaque backdrop, opaque fully-covering source, opacity=1).
[Collection(MediaFixturesCollection.Name)]
public sealed class BlendModeTests(MediaFixtures fixtures)
{
    private static string LoadTemplateJson(string blendMode, string fixtureDir) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "blend-mode-template.snapshot.json"))
            .Replace("{{FIXTURE_DIR}}", fixtureDir.Replace("\\", "\\\\"))
            .Replace("__BLEND_MODE__", blendMode);

    private static string RenderToTempPng(TimelineSession timeline, long frame)
    {
        string path = Path.Combine(Path.GetTempPath(), $"palmier-blend-{Guid.NewGuid():N}.png");
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
    public void Multiply_RedOverBlue_IsBlack()
    {
        // Multiply(Cb=blue(0,0,1), Cs=red(1,0,0)) = Cb*Cs = (0,0,0) componentwise; both layers
        // opaque and opacity=1 so the PDF composite collapses to exactly the blend result.
        using var session = new EngineSession();
        string json = LoadTemplateJson("multiply", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));
        string pngPath = RenderToTempPng(timeline, 15);
        try
        {
            using var bitmap = new Bitmap(pngPath);
            AssertColorNear(bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2), Color.Black, tolerance: 10);
        }
        finally
        {
            File.Delete(pngPath);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void Screen_RedOverBlue_IsMagenta()
    {
        // Screen(Cb=blue, Cs=red) = Cb+Cs-Cb*Cs = (1,0,1) -> magenta.
        using var session = new EngineSession();
        string json = LoadTemplateJson("screen", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));
        string pngPath = RenderToTempPng(timeline, 15);
        try
        {
            using var bitmap = new Bitmap(pngPath);
            AssertColorNear(bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2), Color.Magenta, tolerance: 10);
        }
        finally
        {
            File.Delete(pngPath);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void Hue_NonSeparable_HueOfSourcePreserved_LuminosityOfBackdropPreserved()
    {
        // Hue(Cb,Cs) = SetLum(SetSat(Cs, Sat(Cb)), Lum(Cb)). Hand-computed (0.3/0.59/0.11 luma
        // weights, matching Common.hlsl's Lum): Cb=blue(0,0,1) has Sat=1, Lum=0.11;
        // SetSat(red,1) is a no-op (red is already fully saturated) -> (1,0,0); SetLum((1,0,0),
        // 0.11) requires clipping (green/blue channels go negative) -> (0.3667, 0, 0).
        using var session = new EngineSession();
        string json = LoadTemplateJson("hue", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));
        string pngPath = RenderToTempPng(timeline, 15);
        try
        {
            using var bitmap = new Bitmap(pngPath);
            Color pixel = bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2);

            // Hue of result preserved: only the red channel is non-trivial (green/blue ~0) —
            // the result is still a pure-red hue, exactly like the source.
            ((int)pixel.G).ShouldBeLessThanOrEqualTo(6);
            ((int)pixel.B).ShouldBeLessThanOrEqualTo(6);
            Math.Abs(pixel.R - 94).ShouldBeLessThanOrEqualTo(8, $"R channel: actual={pixel.R}, expected~94 (0.3667*255)");

            // Luminosity of the backdrop preserved (within tolerance): 0.3*R + 0.59*G + 0.11*B
            // should reproduce Lum(blue)=0.11 -> ~28/255.
            double luminosity = 0.3 * pixel.R + 0.59 * pixel.G + 0.11 * pixel.B;
            Math.Abs(luminosity - 28.05).ShouldBeLessThanOrEqualTo(8, $"luminosity={luminosity}, expected~28.05 (0.11*255)");
        }
        finally
        {
            File.Delete(pngPath);
        }
    }
}
