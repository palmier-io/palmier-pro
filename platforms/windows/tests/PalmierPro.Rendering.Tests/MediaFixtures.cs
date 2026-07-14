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

    public const int VideoWidth = 640;
    public const int VideoHeight = 360;
    public const int VideoFps = 30;
    public const double VideoDurationSeconds = 2.0;

    public MediaFixtures()
    {
        string fixturesDir = Path.Combine(AppContext.BaseDirectory, "fixtures");
        Directory.CreateDirectory(fixturesDir);

        VideoWithAudioPath = Path.Combine(fixturesDir, "video_640x360_30fps_2s.mp4");
        AudioOnlyPath = Path.Combine(fixturesDir, "audio_sine_1khz_2s.wav");

        EnsureVideoFixture(VideoWithAudioPath);
        EnsureAudioFixture(AudioOnlyPath);
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
