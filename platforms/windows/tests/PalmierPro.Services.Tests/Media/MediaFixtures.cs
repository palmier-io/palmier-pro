using System.Diagnostics;
using Xunit;

namespace PalmierPro.Services.Tests.Media;

// Generates tiny fixture media with the pinned ffmpeg.exe (third_party/ffmpeg/bin, restored by
// scripts/ci-restore-ffmpeg.ps1) the first time it's needed, then reuses the files already sitting
// in the test output dir on subsequent runs. Deliberately not shared with
// PalmierPro.Rendering.Tests.MediaFixtures — a test project depending on another test project is
// more coupling than this small a need justifies (same rationale as TestSupport.cs's TestFixtures).
public sealed class MediaFixtures
{
    public string VideoWithAudioPath { get; }
    public string PortraitVideoPath { get; }
    public string PngStillPath { get; }

    public const int VideoWidth = 640;
    public const int VideoHeight = 360;
    public const int VideoFps = 30;
    public const double VideoDurationSeconds = 2.0;
    public const int PortraitVideoWidth = 360;
    public const int PortraitVideoHeight = 640;
    public const int PngWidth = 64;
    public const int PngHeight = 48;

    public MediaFixtures()
    {
        string fixturesDir = Path.Combine(AppContext.BaseDirectory, "fixtures");
        Directory.CreateDirectory(fixturesDir);

        VideoWithAudioPath = Path.Combine(fixturesDir, "video_640x360_30fps_2s.mp4");
        PortraitVideoPath = Path.Combine(fixturesDir, "video_360x640_30fps_2s.mp4");
        PngStillPath = Path.Combine(fixturesDir, "still_64x48.png");

        EnsureVideoFixture(VideoWithAudioPath, VideoWidth, VideoHeight);
        EnsureVideoFixture(PortraitVideoPath, PortraitVideoWidth, PortraitVideoHeight);
        EnsurePngFixture(PngStillPath);
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

    private static void EnsureVideoFixture(string path, int width, int height)
    {
        if (IsNonEmpty(path))
        {
            return;
        }
        Run(
            "-y " +
            $"-f lavfi -i \"testsrc2=size={width}x{height}:rate={VideoFps}:duration={VideoDurationSeconds}\" " +
            $"-f lavfi -i \"sine=frequency=1000:duration={VideoDurationSeconds}\" " +
            "-c:v libx264 -pix_fmt yuv420p -c:a aac -shortest " +
            $"\"{path}\"");
    }

    private static void EnsurePngFixture(string path)
    {
        if (IsNonEmpty(path))
        {
            return;
        }
        Run($"-y -f lavfi -i \"color=c=blue:s={PngWidth}x{PngHeight}\" -frames:v 1 \"{path}\"");
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
