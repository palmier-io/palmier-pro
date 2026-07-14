using System.Drawing;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

[Collection(MediaFixturesCollection.Name)]
public sealed class RenderFrameToFileTests(MediaFixtures fixtures)
{
    private static readonly byte[] PngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

    [Fact]
    [Trait("Category", "Media")]
    public void RenderFrameToFile_ProducesDecodablePng()
    {
        using var session = new EngineSession();
        using MediaSource media = session.OpenMedia(fixtures.VideoWithAudioPath);

        string pngPath = Path.Combine(Path.GetTempPath(), $"palmier-render-frame-{Guid.NewGuid():N}.png");
        try
        {
            media.RenderFrameToFile(0.5, pngPath);

            byte[] bytes = File.ReadAllBytes(pngPath);
            bytes.Length.ShouldBeGreaterThan(PngSignature.Length, "PNG should carry real pixel data, not just a header");
            bytes[..PngSignature.Length].ShouldBe(PngSignature);

            using var bitmap = new Bitmap(pngPath);
            bitmap.Width.ShouldBe(MediaFixtures.VideoWidth);
            bitmap.Height.ShouldBe(MediaFixtures.VideoHeight);

            bool sawNonBlackPixel = false;
            for (int y = 0; y < bitmap.Height && !sawNonBlackPixel; y += 7)
            {
                for (int x = 0; x < bitmap.Width && !sawNonBlackPixel; x += 7)
                {
                    Color pixel = bitmap.GetPixel(x, y);
                    if (pixel.R > 8 || pixel.G > 8 || pixel.B > 8)
                    {
                        sawNonBlackPixel = true;
                    }
                }
            }
            sawNonBlackPixel.ShouldBeTrue("decoded testsrc2 frame should not be an all-black PNG");
        }
        finally
        {
            File.Delete(pngPath);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void RenderFrameToFile_AudioOnlyMedia_ThrowsEngineException()
    {
        using var session = new EngineSession();
        using MediaSource media = session.OpenMedia(fixtures.AudioOnlyPath);

        string pngPath = Path.Combine(Path.GetTempPath(), $"palmier-render-frame-{Guid.NewGuid():N}.png");
        Should.Throw<EngineException>(() => media.RenderFrameToFile(0.5, pngPath));
    }
}
