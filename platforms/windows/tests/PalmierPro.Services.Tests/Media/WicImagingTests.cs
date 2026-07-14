using PalmierPro.Core.Models;
using PalmierPro.Services.Media;
using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests.Media;

[Collection(MediaFixturesCollection.Name)]
public sealed class WicImagingTests(MediaFixtures fixtures)
{
    [Fact]
    [Trait("Category", "Media")]
    public async Task ProbeImageAsync_ReportsPixelDimensions_WithoutAnEngineSession()
    {
        ImageProbeResult? result = await WicImaging.ProbeImageAsync(fixtures.PngStillPath);

        result.ShouldNotBeNull();
        result!.Width.ShouldBe(MediaFixtures.PngWidth);
        result.Height.ShouldBe(MediaFixtures.PngHeight);
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task ProbeImageAsync_MissingFile_ReturnsNullRatherThanThrowing()
    {
        (await WicImaging.ProbeImageAsync(Path.Combine(Path.GetTempPath(), "palmier-does-not-exist.png"))).ShouldBeNull();
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task CreateThumbnailJpegAsync_ScalesDownToFitTheRequestedMaxSize_PreservingAspect()
    {
        using var tmp = new TempDirectory();
        byte[]? jpeg = await WicImaging.CreateThumbnailJpegAsync(fixtures.PngStillPath, maxPixelSize: 32);

        jpeg.ShouldNotBeNull();
        jpeg!.Length.ShouldBeGreaterThan(0);

        var decoded = await WicImaging.DecodeToBgraAsync(WriteTemp(tmp, jpeg));
        decoded.ShouldNotBeNull();
        // 64x48 source, longest edge capped at 32 -> exactly half: 32x24.
        decoded!.Value.Width.ShouldBe(32);
        decoded.Value.Height.ShouldBe(24);
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task CreateThumbnailJpegAsync_NeverUpscales_WhenSourceIsSmallerThanMaxSize()
    {
        using var tmp = new TempDirectory();
        byte[]? jpeg = await WicImaging.CreateThumbnailJpegAsync(fixtures.PngStillPath, maxPixelSize: 4000);

        var decoded = await WicImaging.DecodeToBgraAsync(WriteTemp(tmp, jpeg!));
        decoded!.Value.Width.ShouldBe(MediaFixtures.PngWidth);
        decoded.Value.Height.ShouldBe(MediaFixtures.PngHeight);
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task EncodeBgraAsJpegAsync_RoundTripsDimensions_ForARawBuffer()
    {
        using var tmp = new TempDirectory();
        const int width = 16;
        const int height = 8;
        const int stride = width * 4;
        var bgra = new byte[stride * height];
        for (int i = 0; i < bgra.Length; i += 4)
        {
            bgra[i] = 10;      // B
            bgra[i + 1] = 20;  // G
            bgra[i + 2] = 200; // R
            bgra[i + 3] = 255; // A
        }

        byte[]? jpeg = await WicImaging.EncodeBgraAsJpegAsync(bgra, width, height, stride);

        jpeg.ShouldNotBeNull();
        var decoded = await WicImaging.DecodeToBgraAsync(WriteTemp(tmp, jpeg!));
        decoded.ShouldNotBeNull();
        decoded!.Value.Width.ShouldBe(width);
        decoded.Value.Height.ShouldBe(height);
        decoded.Value.Bgra.Length.ShouldBe(stride * height);
    }

    private static string WriteTemp(TempDirectory tmp, byte[] bytes)
    {
        string path = Path.Combine(tmp.Path, $"{Guid.NewGuid():N}.jpg");
        File.WriteAllBytes(path, bytes);
        return path;
    }
}
