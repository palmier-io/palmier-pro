using System.Diagnostics;
using System.Text.Json;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// Isolated PE_EncodeAlphaVideo* golden hook (docs/lottie-bake-v1.md §14's "PE_EncodeAlphaVideo*
// in isolation" bullet) — pushes synthetic BGRA frames with no ThorVG/Lottie file involved, then
// validates the resulting .mov two ways: structurally via the real ffprobe.exe (codec/pix_fmt/
// frame count/duration), and by decoding a frame back through the engine's own MediaSource to
// confirm a known pixel + its alpha survive the BGRA -> yuva444p10le -> BGRA round trip.
public sealed class AlphaVideoEncoderTests
{
    private const int Width = 64;
    private const int Height = 64;
    private const int Fps = 30;
    private const int FrameCount = 30;

    // Left half: fully opaque muted red. Right half: partially transparent muted blue. Deliberately
    // unsaturated (not 0/255 primaries) to keep the BGRA -> YUVA444P10LE -> BGRA color-matrix
    // round trip well away from chroma clipping — this test cares whether roughly the right color
    // and alpha survive encode+decode, not bit-exact color science.
    private const byte OpaqueB = 60, OpaqueG = 60, OpaqueR = 200, OpaqueA = 255;
    private const byte TranslucentStraightB = 200, TranslucentStraightG = 60, TranslucentStraightR = 60;
    private const byte TranslucentA = 110;

    private static byte[] MakeFrame(int width, int height, out int strideBytes)
    {
        strideBytes = width * 4;
        var buffer = new byte[strideBytes * height];
        int half = width / 2;
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                int offset = y * strideBytes + x * 4;
                if (x < half)
                {
                    buffer[offset + 0] = OpaqueB;
                    buffer[offset + 1] = OpaqueG;
                    buffer[offset + 2] = OpaqueR;
                    buffer[offset + 3] = OpaqueA;
                }
                else
                {
                    // Premultiplied: straight channel * alpha / 255 — matches PE_EncodeAlphaVideoPushFrame's
                    // "premultiplied BGRA32" contract (palmier_engine.h).
                    buffer[offset + 0] = (byte)(TranslucentStraightB * TranslucentA / 255);
                    buffer[offset + 1] = (byte)(TranslucentStraightG * TranslucentA / 255);
                    buffer[offset + 2] = (byte)(TranslucentStraightR * TranslucentA / 255);
                    buffer[offset + 3] = TranslucentA;
                }
            }
        }
        return buffer;
    }

    private static string EncodeFixture(EngineSession session, int frameCount = FrameCount, double frameSpacingSeconds = 1.0 / Fps)
    {
        string path = Path.Combine(Path.GetTempPath(), $"palmier-alpha-encode-{Guid.NewGuid():N}.mov");
        byte[] frame = MakeFrame(Width, Height, out int stride);

        using AlphaVideoEncoder encoder = AlphaVideoEncoder.Open(session, path, Width, Height);
        for (int i = 0; i < frameCount; i++)
        {
            encoder.PushFrame(frame, stride, i * frameSpacingSeconds);
        }
        encoder.Close();
        return path;
    }

    [Fact]
    [Trait("Category", "Media")]
    public void Close_ThirtyFrames_ProducesFfprobeValidProResAlphaMov()
    {
        using var session = new EngineSession();
        string path = EncodeFixture(session);
        try
        {
            File.Exists(path).ShouldBeTrue();
            new FileInfo(path).Length.ShouldBeGreaterThan(0);

            FfprobeStream stream = Ffprobe.ProbeFirstVideoStream(path);

            stream.CodecName.ShouldBe("prores");
            stream.Profile.ShouldBe("4444");
            // Real-world quirk (confirmed against this repo's pinned ffprobe.exe): FFmpeg's ProRes
            // decoder always reports the 4444 profile's actual internal working precision
            // (yuva444p12le) regardless of the 10-bit pix_fmt the encoder was opened with (doc §7 —
            // AV_PIX_FMT_YUVA444P10LE is the CODED/input format, not what a decoder reports back).
            // "yuva" is the part this test actually cares about: alpha is present at all.
            // (ffprobe always reports pix_fmt names lowercase — no case-insensitive compare needed.)
            stream.PixFmt.ShouldStartWith("yuva");
            stream.NbReadFrames.ShouldBe(FrameCount);
            stream.Width.ShouldBe(Width);
            stream.Height.ShouldBe(Height);
            // 30 frames spaced 1/30s apart span just under 1s on the wire; generous either side to
            // absorb how the mov muxer infers the final (unset-duration) packet's own length.
            stream.DurationSeconds.ShouldBeInRange(0.8, 1.3);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void Close_ThenDecodedThroughMediaSource_RoundTripsKnownPixelAndAlpha()
    {
        using var session = new EngineSession();
        string path = EncodeFixture(session);
        try
        {
            using MediaSource media = session.OpenMedia(path);
            media.Info.HasVideo.ShouldBeTrue();
            media.Info.HasAlpha.ShouldBeTrue();
            media.Info.Width.ShouldBe(Width);
            media.Info.Height.ShouldBe(Height);

            DecodedFrame frame = media.DecodeFrameAt(0.0);
            ReadOnlySpan<byte> bgra = frame.Bgra.Span;

            (byte b, byte g, byte r, byte a) opaque = PixelAt(bgra, frame.StrideBytes, x: 8, y: Height / 2);
            AssertNear(opaque.b, OpaqueB);
            AssertNear(opaque.g, OpaqueG);
            AssertNear(opaque.r, OpaqueR);
            AssertNear(opaque.a, OpaqueA);

            (byte b, byte g, byte r, byte a) translucent = PixelAt(bgra, frame.StrideBytes, x: Width - 8, y: Height / 2);
            AssertNear(translucent.b, (byte)(TranslucentStraightB * TranslucentA / 255));
            AssertNear(translucent.g, (byte)(TranslucentStraightG * TranslucentA / 255));
            AssertNear(translucent.r, (byte)(TranslucentStraightR * TranslucentA / 255));
            AssertNear(translucent.a, TranslucentA);

            // The whole point of the alpha channel: the translucent region really is more
            // transparent than the opaque one, not just numerically close by coincidence.
            translucent.a.ShouldBeLessThan(opaque.a);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void PushFrame_NonIncreasingPresentationSeconds_ThrowsEngineException()
    {
        using var session = new EngineSession();
        string path = Path.Combine(Path.GetTempPath(), $"palmier-alpha-encode-{Guid.NewGuid():N}.mov");
        byte[] frame = MakeFrame(Width, Height, out int stride);
        try
        {
            using AlphaVideoEncoder encoder = AlphaVideoEncoder.Open(session, path, Width, Height);
            encoder.PushFrame(frame, stride, 0.5);

            Should.Throw<EngineException>(() => encoder.PushFrame(frame, stride, 0.5));
            Should.Throw<EngineException>(() => encoder.PushFrame(frame, stride, 0.4));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void PushFrame_LargeGap_EncodesAsSingleHoldTailSampleNotRepeatedFrames()
    {
        using var session = new EngineSession();
        string path = Path.Combine(Path.GetTempPath(), $"palmier-alpha-encode-{Guid.NewGuid():N}.mov");
        byte[] frame = MakeFrame(Width, Height, out int stride);
        try
        {
            using (AlphaVideoEncoder encoder = AlphaVideoEncoder.Open(session, path, Width, Height))
            {
                encoder.PushFrame(frame, stride, 0.0);
                encoder.PushFrame(frame, stride, 5.0); // freeze-frame hold tail (doc §6/§8)
                encoder.Close();
            }

            FfprobeStream stream = Ffprobe.ProbeFirstVideoStream(path);
            // 2 PushFrame calls -> 3 samples in the file: Close()'s own confirmed mov-muxer-defect
            // workaround (AlphaVideoEncoder.cpp's Close() comment) appends one small-gap "closing"
            // sample after any large-gap last sample, since this build's mov muxer silently drops
            // the literal last sample of a track whenever its own gap from the previous one exceeds
            // a few hundred ms — every OTHER sample (including this hold tail itself) survives fine
            // regardless of gap size once it's no longer the last one. Not "repeated frames" in the
            // sense this test's name guards against (a naive fix would insert dozens of duplicate
            // frames to fill the gap) — one extra, imperceptible sub-frame-duration sample.
            stream.NbReadFrames.ShouldBe(3, "a hold tail is one extra sample (plus one small closing sample the mov-muxer workaround needs), not dozens of repeated frames");
            stream.DurationSeconds.ShouldBeGreaterThan(4.0, "the container should reflect the hold, not just the first sample");
        }
        finally
        {
            File.Delete(path);
        }
    }

    private static (byte b, byte g, byte r, byte a) PixelAt(ReadOnlySpan<byte> bgra, int strideBytes, int x, int y)
    {
        int offset = y * strideBytes + x * 4;
        return (bgra[offset + 0], bgra[offset + 1], bgra[offset + 2], bgra[offset + 3]);
    }

    // ProRes 4444 is a high-bitrate, visually-lossless-oriented intra codec over flat regions, but
    // this value still goes through an 8-bit BGRA -> 10-bit YUVA -> lossy-compressed -> 8-bit BGRA
    // round trip — a generous tolerance validates "the right color/alpha survived", not bit-exactness.
    private static void AssertNear(byte actual, byte expected, int tolerance = 24)
    {
        Math.Abs(actual - expected).ShouldBeLessThanOrEqualTo(tolerance,
            $"expected ~{expected}, got {actual} (tolerance {tolerance})");
    }
}

internal sealed record FfprobeStream(
    string CodecName, string? Profile, string PixFmt, int Width, int Height, int NbReadFrames, double DurationSeconds);

// Minimal ffprobe.exe JSON wrapper scoped to this test file — mirrors the resolution/invocation
// pattern already established by MediaFixtures/FfprobeSourceTimingReaderTests' own Fixture helpers.
internal static class Ffprobe
{
    public static FfprobeStream ProbeFirstVideoStream(string path)
    {
        string json = Run(
            "-v error -count_frames " +
            "-select_streams v:0 " +
            "-show_entries stream=codec_name,profile,pix_fmt,width,height,nb_read_frames " +
            "-show_entries format=duration " +
            $"-of json \"{path}\"");

        using JsonDocument doc = JsonDocument.Parse(json);
        JsonElement stream = doc.RootElement.GetProperty("streams")[0];
        double duration = doc.RootElement.GetProperty("format").TryGetProperty("duration", out JsonElement d)
            ? double.Parse(d.GetString()!, System.Globalization.CultureInfo.InvariantCulture)
            : 0.0;

        return new FfprobeStream(
            CodecName: stream.GetProperty("codec_name").GetString()!,
            Profile: stream.TryGetProperty("profile", out JsonElement p) ? p.GetString() : null,
            PixFmt: stream.GetProperty("pix_fmt").GetString()!,
            Width: stream.GetProperty("width").GetInt32(),
            Height: stream.GetProperty("height").GetInt32(),
            NbReadFrames: int.Parse(stream.GetProperty("nb_read_frames").GetString()!, System.Globalization.CultureInfo.InvariantCulture),
            DurationSeconds: duration);
    }

    private static string Run(string arguments)
    {
        var psi = new ProcessStartInfo(ResolveFfprobeExe(), arguments)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        using Process process = Process.Start(psi) ?? throw new InvalidOperationException("failed to start ffprobe.exe");
        string stdout = process.StandardOutput.ReadToEnd();
        string stderr = process.StandardError.ReadToEnd();
        process.WaitForExit();
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"ffprobe failed (exit {process.ExitCode}):\n{stderr}");
        }
        return stdout;
    }

    private static string ResolveFfprobeExe()
    {
        string? dir = AppContext.BaseDirectory;
        while (dir is not null)
        {
            string candidate = Path.Combine(dir, "third_party", "ffmpeg", "bin", "ffprobe.exe");
            if (File.Exists(candidate))
            {
                return candidate;
            }
            dir = Path.GetDirectoryName(dir);
        }
        throw new FileNotFoundException(
            "Could not find third_party/ffmpeg/bin/ffprobe.exe above the test output directory. " +
            "Run platforms/windows/scripts/ci-restore-ffmpeg.ps1 first.");
    }
}
