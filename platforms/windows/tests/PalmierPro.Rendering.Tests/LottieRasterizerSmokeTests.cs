using System.Runtime.InteropServices;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// E4.7 vendor slice (docs/lottie-bake-v1.md §16) — exercises the ThorVG-backed
// native/LottieRasterizer.h/.cpp wrapper directly through its test-only smoke seam
// (native/LottieRasterizer.cpp's PE_LottieRasterizerSmokeTest), the same "not yet wired into
// the real PE_BakeLottieVideo orchestration entry point" precedent as RetimeStretcherTests /
// AudioEngineSmokeTests. Fixtures/lottie-shape-move.json is a hand-authored, minimal
// one-shape (filled rectangle) Lottie animation: 30 frames at 30 fps, the shape's position
// keyframed from x=20 to x=80 (LottieRasterizerSmokeTests-only concern — no timeline/bake
// service involved), so frame 0 and the last frame are guaranteed to differ.
public sealed class LottieRasterizerSmokeTests
{
    // Test-local P/Invoke (DllImport, not the LibraryImport source generator) into the smoke
    // seam exported from native/LottieRasterizer.cpp — deliberately not routed through
    // NativeMethods.cs, mirroring AudioEngineSmokeTests' own precedent.
    [DllImport("PalmierEngine.dll")]
    private static extern int PE_LottieRasterizerSmokeTest(
        string utf8LottiePath,
        int width,
        int height,
        byte[] outFrame0Bgra,
        byte[] outLastFrameBgra,
        out int outFrameCount,
        out double outFrameRate,
        out double outDurationSeconds);

    private const int Width = 64;
    private const int Height = 64;

    private static string FixturePath => Path.Combine(AppContext.BaseDirectory, "Fixtures", "lottie-shape-move.json");

    private static bool HasNonTransparentPixel(byte[] bgra)
    {
        for (int i = 3; i < bgra.Length; i += 4)
        {
            if (bgra[i] != 0)
            {
                return true;
            }
        }
        return false;
    }

    [Fact]
    [Trait("Category", "Media")]
    public void RasterizeFrame_ProducesNonEmptyPixelsAndFrame0DiffersFromLastFrame()
    {
        byte[] frame0 = new byte[Width * Height * 4];
        byte[] frameLast = new byte[Width * Height * 4];

        int rc = PE_LottieRasterizerSmokeTest(
            FixturePath, Width, Height, frame0, frameLast,
            out int frameCount, out double frameRate, out double durationSeconds);

        rc.ShouldBe(0);
        frameCount.ShouldBe(30);
        frameRate.ShouldBe(30.0, tolerance: 0.01);
        durationSeconds.ShouldBe(1.0, tolerance: 0.01);

        // Non-empty pixels: the rasterized rectangle actually painted something (premultiplied
        // BGRA — a fully-transparent buffer would leave every alpha byte at 0, doc §7).
        HasNonTransparentPixel(frame0).ShouldBeTrue("frame 0 should render the shape, not a blank buffer");
        HasNonTransparentPixel(frameLast).ShouldBeTrue("the last frame should render the shape, not a blank buffer");

        // Frame 0 != frame N: the fixture's position keyframe (x: 20 -> 80) moves the shape
        // fully out of frame 0's footprint by the last frame, so the two buffers must differ
        // byte-for-byte, not just "some pixel changed slightly."
        frame0.ShouldNotBe(frameLast);
    }
}
