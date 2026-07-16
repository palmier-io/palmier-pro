using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// docs/lottie-bake-v1.md §14's "PE_BakeLottieVideo end-to-end" + "PE_ProbeLottieMetadata" bullets —
// exercises the real orchestration entry point (native/LottieBaker.cpp), composing the vendor
// slice's LottieRasterizer with the encode slice's AlphaVideoEncoder, against the same checked-in
// fixture LottieRasterizerSmokeTests uses (Fixtures/lottie-shape-move.json: 30 frames @ 30fps, 1s,
// a 100x100 comp with an opaque rectangle keyframed across a transparent background).
public sealed class LottieBakeTests
{
    private const int Width = 64;
    private const int Height = 64;

    private static string FixturePath => Path.Combine(AppContext.BaseDirectory, "Fixtures", "lottie-shape-move.json");

    [Fact]
    [Trait("Category", "Media")]
    public void BakeLottieVideo_EndToEnd_ProducesFfprobeValidProResAlphaMovWithHoldTail()
    {
        using var session = new EngineSession();
        string outputPath = Path.Combine(Path.GetTempPath(), $"palmier-lottie-bake-{Guid.NewGuid():N}.mov");
        try
        {
            var progressCalls = new List<(int Done, int Total)>();
            session.BakeLottieVideo(
                FixturePath, Width, Height, holdTailSeconds: 2.0, outputPath,
                onProgress: (done, total) => progressCalls.Add((done, total)));

            File.Exists(outputPath).ShouldBeTrue();
            new FileInfo(outputPath).Length.ShouldBeGreaterThan(0);

            // One progress callback per rasterized animation frame (not the hold-tail sample) — doc §8.
            progressCalls.Count.ShouldBe(30);
            progressCalls[^1].ShouldBe((30, 30));

            FfprobeStream stream = Ffprobe.ProbeFirstVideoStream(outputPath);
            stream.CodecName.ShouldBe("prores");
            stream.Profile.ShouldBe("4444");
            stream.PixFmt.ShouldStartWith("yuva");
            stream.Width.ShouldBe(Width);
            stream.Height.ShouldBe(Height);
            // Hold tail (doc §6/§8): the fixture's own last frame, held out to
            // max(holdTailSeconds, duration + 1) = max(2.0, 1.0 + 1) = 2.0s — one extra sample, not
            // 30fps worth of repeated frames, so 30 real frames + 1 hold-tail sample = 31 — plus one
            // more small-gap "closing" sample AlphaVideoEncoder.Close() appends after any large-gap
            // last sample (see its own comment): a confirmed mov-muxer defect otherwise silently
            // drops the literal last sample of a track whenever its gap from the previous one is
            // more than a few hundred ms, which the hold tail always is by construction.
            stream.NbReadFrames.ShouldBe(32);
            stream.DurationSeconds.ShouldBeGreaterThan(1.8);

            using MediaSource media = session.OpenMedia(outputPath);
            media.Info.HasAlpha.ShouldBeTrue();
            DecodedFrame frame = media.DecodeFrameAt(0.0);
            HasBothOpaqueAndTransparentPixels(frame.Bgra.Span).ShouldBeTrue(
                "the fixture's rectangle-over-transparent-background composition should leave alpha non-trivial, not uniformly opaque");
        }
        finally
        {
            File.Delete(outputPath);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void ProbeLottieMetadata_ReturnsFixtureKnownValues()
    {
        using var session = new EngineSession();
        LottieInfo info = session.ProbeLottieMetadata(FixturePath);

        info.Width.ShouldBe(100.0, tolerance: 0.01);
        info.Height.ShouldBe(100.0, tolerance: 0.01);
        info.FrameRate.ShouldBe(30.0, tolerance: 0.01);
        info.DurationSeconds.ShouldBe(1.0, tolerance: 0.01);
    }

    [Fact]
    [Trait("Category", "Media")]
    public void ProbeLottieMetadata_InvalidPath_ThrowsEngineException()
    {
        using var session = new EngineSession();
        Should.Throw<EngineException>(() => session.ProbeLottieMetadata(Path.Combine(Path.GetTempPath(), $"no-such-lottie-{Guid.NewGuid():N}.json")));
    }

    [Fact]
    [Trait("Category", "Media")]
    public void BakeLottieVideo_CancelledBeforeStart_ThrowsAndLeavesNoOutputFile()
    {
        using var session = new EngineSession();
        string outputPath = Path.Combine(Path.GetTempPath(), $"palmier-lottie-bake-{Guid.NewGuid():N}.mov");
        try
        {
            using var cts = new CancellationTokenSource();
            cts.Cancel();
            Should.Throw<OperationCanceledException>(() =>
                session.BakeLottieVideo(FixturePath, Width, Height, holdTailSeconds: 2.0, outputPath, ct: cts.Token));

            File.Exists(outputPath).ShouldBeFalse("doc §8: any failure or cancellation leaves no file at utf8OutputPath at all");
        }
        finally
        {
            File.Delete(outputPath);
        }
    }

    private static bool HasBothOpaqueAndTransparentPixels(ReadOnlySpan<byte> bgra)
    {
        bool sawOpaque = false, sawTransparent = false;
        for (int i = 3; i < bgra.Length; i += 4)
        {
            if (bgra[i] == 255)
            {
                sawOpaque = true;
            }
            else if (bgra[i] == 0)
            {
                sawTransparent = true;
            }
            if (sawOpaque && sawTransparent)
            {
                return true;
            }
        }
        return false;
    }
}
