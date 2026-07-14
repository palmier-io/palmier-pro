using PalmierPro.Core.Json;
using PalmierPro.Core.Models;

namespace PalmierPro.Services.Tests;

/// Self-contained isolated directory for one test; deleted best-effort on dispose so a failed
/// assertion doesn't leak temp files across the suite.
internal sealed class TempDirectory : IDisposable
{
    public string Path { get; }

    public TempDirectory()
    {
        Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "PalmierProServicesTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(Path))
            {
                Directory.Delete(Path, recursive: true);
            }
        }
        catch (IOException)
        {
            // Best effort — a lingering handle shouldn't fail the test run.
        }
    }
}

/// Minimal, self-contained model builders — deliberately not shared with
/// `PalmierPro.Core.Tests.Fixtures` (a test project depending on another test project is more
/// coupling than this small a need justifies).
internal static class TestFixtures
{
    public static Clip Clip(string mediaRef = "media-1", int start = 0, int duration = 30) =>
        new(mediaRef, start, duration) { Id = SwiftId.New() };

    public static Track VideoTrack(params Clip[] clips) =>
        new(ClipType.Video, [.. clips]) { Id = SwiftId.New() };

    public static Timeline Timeline(params Track[] tracks) =>
        new() { Tracks = [.. tracks] };
}
