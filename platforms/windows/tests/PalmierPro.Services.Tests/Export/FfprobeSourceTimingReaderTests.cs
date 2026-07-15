using System.Diagnostics;
using PalmierPro.Core.Export;
using PalmierPro.Services.Export;
using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests.Export;

/// Exercises `FfprobeSourceTimingReader` against real ffmpeg-generated fixtures. Every other
/// exporter test injects `FakeSourceTimingReader` so it never launches a process; these are the
/// seam tests confirming the real ffprobe.exe JSON parsing (SMPTE timecode + creation_time) still
/// works end to end. Both fixtures reproduce a real ffprobe quirk that once broke parsing: a
/// `tmcd` stream's own `r_frame_rate` is "0/0" (data streams have no frame rate of their own), so
/// the reader must fall back to `avg_frame_rate` rather than stopping at the first non-null value.
[Trait("Category", "Media")]
public sealed class FfprobeSourceTimingReaderTests
{
    [Fact]
    public async Task ReadAsync_NonDropFrameTimecode_ParsesFrameCountAndCreationTime()
    {
        var reader = new FfprobeSourceTimingReader();

        SourceTiming timing = await reader.ReadAsync(Fixture.NonDropFramePath.Value);

        timing.Timecode.ShouldNotBeNull();
        SourceTimecode tc = timing.Timecode!.Value;
        tc.Quanta.ShouldBe(25);
        tc.DropFrame.ShouldBeFalse();
        tc.Frame.ShouldBe(255); // 00:00:10:05 @ 25fps non-drop: 25*10 + 5

        timing.CaptureDate.ShouldBe(DateTimeOffset.Parse("2020-01-02T03:04:05Z"));
    }

    [Fact]
    public async Task ReadAsync_DropFrameTimecode_UndoesTheDropFrameFormula()
    {
        var reader = new FfprobeSourceTimingReader();

        SourceTiming timing = await reader.ReadAsync(Fixture.DropFramePath.Value);

        timing.Timecode.ShouldNotBeNull();
        SourceTimecode tc = timing.Timecode!.Value;
        tc.Quanta.ShouldBe(30);
        tc.DropFrame.ShouldBeTrue();
        tc.Frame.ShouldBe(1803); // 00:01:00;05 @ 29.97fps drop-frame; round-trips through FormatTimecode

        timing.CaptureDate.ShouldBe(DateTimeOffset.Parse("2021-06-15T12:00:00Z"));
    }

    [Fact]
    public async Task TimecodesAsync_MapsMediaRefToParsedTimecode_ForResolvableUrlsOnly()
    {
        var reader = new FfprobeSourceTimingReader();
        var urls = new Dictionary<string, string> { ["clip-a"] = Fixture.NonDropFramePath.Value };

        Dictionary<string, SourceTimecode> result =
            await reader.TimecodesAsync(["clip-a", "clip-unresolved"], urls);

        result.ShouldContainKey("clip-a");
        result["clip-a"].Frame.ShouldBe(255);
        result.ShouldNotContainKey("clip-unresolved");
    }

    [Fact]
    public async Task ReadAsync_MissingFile_ReturnsDefaultRatherThanThrowing()
    {
        var reader = new FfprobeSourceTimingReader();

        SourceTiming timing = await reader.ReadAsync(Path.Combine(Path.GetTempPath(), "palmier-does-not-exist.mp4"));

        timing.ShouldBe(default);
    }

    [Fact]
    public async Task ReadAsync_CachesByFullPath_SecondCallReturnsTheSameResult()
    {
        var reader = new FfprobeSourceTimingReader();

        SourceTiming first = await reader.ReadAsync(Fixture.NonDropFramePath.Value);
        SourceTiming second = await reader.ReadAsync(Fixture.NonDropFramePath.Value);

        second.ShouldBe(first);
    }
}

/// Tiny ffmpeg-generated fixtures scoped to this test file — distinct from the shared
/// `Media.MediaFixtures` (that project-wide set has no embedded timecode/creation_time). Cached
/// under the test output dir the same way `MediaFixtures` is, so repeated runs don't re-invoke
/// ffmpeg.exe.
file static class Fixture
{
    public static readonly Lazy<string> NonDropFramePath = new(() => Create(
        "timecode_25fps_nondrop.mp4", "testsrc2=size=64x64:rate=25:duration=1",
        timecode: "00:00:10:05", creationTime: "2020-01-02T03:04:05.000000Z"));

    public static readonly Lazy<string> DropFramePath = new(() => Create(
        "timecode_2997fps_drop.mp4", "testsrc2=size=64x64:rate=30000/1001:duration=1",
        timecode: "00:01:00;05", creationTime: "2021-06-15T12:00:00.000000Z"));

    private static string Create(string fileName, string lavfiSource, string timecode, string creationTime)
    {
        var dir = Path.Combine(AppContext.BaseDirectory, "fixtures");
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, fileName);
        if (File.Exists(path) && new FileInfo(path).Length > 0)
        {
            return path;
        }
        Run(
            $"-y -f lavfi -i \"{lavfiSource}\" -timecode \"{timecode}\" -metadata creation_time={creationTime} " +
            $"-c:v libx264 -pix_fmt yuv420p \"{path}\"");
        return path;
    }

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

    private static string ResolveFfmpegExe()
    {
        string? dir = AppContext.BaseDirectory;
        while (dir is not null)
        {
            var candidate = Path.Combine(dir, "third_party", "ffmpeg", "bin", "ffmpeg.exe");
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
}
