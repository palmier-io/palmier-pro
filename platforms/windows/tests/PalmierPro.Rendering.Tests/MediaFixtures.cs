using System.Diagnostics;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// Generates tiny fixture media with the pinned ffmpeg.exe (third_party/ffmpeg/bin,
// restored by scripts/ci-restore-ffmpeg.ps1) the first time it's needed, then reuses
// the files already sitting in the test output dir on subsequent runs.
public sealed class MediaFixtures
{
    public string VideoWithAudioPath { get; }
    public string AudioOnlyPath { get; }
    public string RedClipPath { get; }
    public string BlueClipPath { get; }
    public string GreenClipPath { get; }
    public string GrayClipPath { get; }

    public const int VideoWidth = 640;
    public const int VideoHeight = 360;
    public const int VideoFps = 30;
    public const double VideoDurationSeconds = 2.0;

    public string FixturesDir { get; }
    /// A hand-written, minimal (2^3) identity `.cube` LUT — every corner maps to itself, so
    /// LUTTetra's tetrahedral interpolation reproduces the input exactly (see CubeLutParser.h /
    /// LUTTetra.hlsl). Used by EffectKernelTests' LUTTetra identity-passthrough test.
    public string IdentityCubePath { get; }

    public MediaFixtures()
    {
        string fixturesDir = Path.Combine(AppContext.BaseDirectory, "fixtures");
        Directory.CreateDirectory(fixturesDir);
        FixturesDir = fixturesDir;

        VideoWithAudioPath = Path.Combine(fixturesDir, "video_640x360_30fps_2s.mp4");
        AudioOnlyPath = Path.Combine(fixturesDir, "audio_sine_1khz_2s.wav");
        RedClipPath = Path.Combine(fixturesDir, "solid_red_640x360_30fps_2s.mp4");
        BlueClipPath = Path.Combine(fixturesDir, "solid_blue_640x360_30fps_2s.mp4");
        GreenClipPath = Path.Combine(fixturesDir, "solid_green_640x360_30fps_2s.mp4");
        GrayClipPath = Path.Combine(fixturesDir, "solid_gray_640x360_30fps_2s.mp4");

        EnsureVideoFixture(VideoWithAudioPath);
        EnsureAudioFixture(AudioOnlyPath);
        EnsureSolidColorFixture(RedClipPath, "red");
        EnsureSolidColorFixture(BlueClipPath, "blue");
        EnsureSolidColorFixture(GreenClipPath, "0x00FF00");
        EnsureSolidColorFixture(GrayClipPath, "0x808080");

        IdentityCubePath = Path.Combine(fixturesDir, "identity.cube");
        EnsureIdentityCube(IdentityCubePath);
    }

    private static void EnsureIdentityCube(string path)
    {
        if (IsNonEmpty(path))
        {
            return;
        }
        // Standard .cube ordering: R fastest, then G, then B.
        var lines = new List<string> { "LUT_3D_SIZE 2" };
        for (int b = 0; b < 2; b++)
        {
            for (int g = 0; g < 2; g++)
            {
                for (int r = 0; r < 2; r++)
                {
                    lines.Add($"{r}.0 {g}.0 {b}.0");
                }
            }
        }
        File.WriteAllLines(path, lines);
    }

    private static string ResolveFfmpegExe()
    {
        string? dir = AppContext.BaseDirectory;
        while (dir is not null)
        {
            string candidate = Path.Combine(dir, "third_party", "ffmpeg", "bin", "ffmpeg.exe");
            if (File.Exists(candidate))
            {
                return candidate;
            }
            dir = Path.GetDirectoryName(dir);
        }
        throw new FileNotFoundException(
            "Could not find third_party/ffmpeg/bin/ffmpeg.exe above the test output directory. " +
            "Run platforms/windows/scripts/ci-restore-ffmpeg.ps1 first.");
    }

    private static void EnsureVideoFixture(string path)
    {
        if (IsNonEmpty(path))
        {
            return;
        }
        Run(
            "-y " +
            $"-f lavfi -i \"testsrc2=size={VideoWidth}x{VideoHeight}:rate={VideoFps}:duration={VideoDurationSeconds}\" " +
            $"-f lavfi -i \"sine=frequency=1000:duration={VideoDurationSeconds}\" " +
            "-c:v libx264 -pix_fmt yuv420p -c:a aac -shortest " +
            $"\"{path}\"");
    }

    private static void EnsureAudioFixture(string path)
    {
        if (IsNonEmpty(path))
        {
            return;
        }
        Run($"-y -f lavfi -i \"sine=frequency=1000:duration={VideoDurationSeconds}\" \"{path}\"");
    }

    // Flat, fully-saturated solid-color clips — used by the compositor tests (top-vs-bottom
    // layer sampling, opacity blend math) where the exact expected pixel value matters and a
    // gradient/testsrc pattern would need per-pixel-position math to verify.
    private static void EnsureSolidColorFixture(string path, string ffmpegColorName)
    {
        if (IsNonEmpty(path))
        {
            return;
        }
        Run(
            "-y " +
            $"-f lavfi -i \"color=c={ffmpegColorName}:size={VideoWidth}x{VideoHeight}:rate={VideoFps}:duration={VideoDurationSeconds}\" " +
            "-c:v libx264 -pix_fmt yuv420p " +
            $"\"{path}\"");
    }

    private static bool IsNonEmpty(string path) => File.Exists(path) && new FileInfo(path).Length > 0;

    private static void Run(string arguments)
    {
        var psi = new ProcessStartInfo(ResolveFfmpegExe(), arguments)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        using Process process = Process.Start(psi) ?? throw new InvalidOperationException("failed to start ffmpeg.exe");
        string stderr = process.StandardError.ReadToEnd();
        process.WaitForExit();
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"ffmpeg fixture generation failed (exit {process.ExitCode}):\n{stderr}");
        }
    }
}

[CollectionDefinition(Name)]
public sealed class MediaFixturesCollection : ICollectionFixture<MediaFixtures>
{
    public const string Name = "Media fixtures";
}
