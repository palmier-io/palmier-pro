using System.Globalization;
using System.Text.Json;
using PalmierPro.Core.Json;
using PalmierPro.Core.Models;
using PalmierPro.Rendering;
using PalmierPro.Services.Engine;
using PalmierPro.Services.Export;
using PalmierPro.Services.Project;

namespace PalmierPro.DevHarness;

// Hand-written Main (DISABLE_XAML_GENERATED_MAIN in the csproj) so --dump-frame/
// --dump-timeline-frame/--export-fcpxml can run headless — no Application.Start, no WinUI/display
// dependency at all — before falling through to the normal WinUI-hosted app. Keeps the
// CI-facing path minimal per the plan:
//   PalmierPro.DevHarness.exe --dump-frame <media> <seconds> <outPng>
//   PalmierPro.DevHarness.exe --dump-timeline-frame <projectOrSnapshotPath> <frame> <outPng>
//   PalmierPro.DevHarness.exe --export-fcpxml <outFcpxmlPath>
public static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length >= 1 && string.Equals(args[0], "--dump-frame", StringComparison.OrdinalIgnoreCase))
        {
            return RunDumpFrame(args);
        }
        if (args.Length >= 1 && string.Equals(args[0], "--dump-timeline-frame", StringComparison.OrdinalIgnoreCase))
        {
            return RunDumpTimelineFrame(args);
        }
        if (args.Length >= 1 && string.Equals(args[0], "--export-fcpxml", StringComparison.OrdinalIgnoreCase))
        {
            return RunExportFcpxml(args);
        }

        HarnessLogging.Configure();
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Microsoft.UI.Xaml.Application.Start(p =>
        {
            var context = new Microsoft.UI.Dispatching.DispatcherQueueSynchronizationContext(
                Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            new App();
        });
        return 0;
    }

    private static int RunDumpFrame(string[] args)
    {
        if (args.Length != 4)
        {
            Console.Error.WriteLine("usage: PalmierPro.DevHarness.exe --dump-frame <mediaPath> <seconds> <outPngPath>");
            return 1;
        }
        string mediaPath = args[1];
        string outPngPath = args[3];
        if (!double.TryParse(args[2], NumberStyles.Float, CultureInfo.InvariantCulture, out double seconds))
        {
            Console.Error.WriteLine($"--dump-frame: invalid seconds value '{args[2]}'");
            return 1;
        }

        try
        {
            using var session = new EngineSession();
            using PalmierPro.Rendering.MediaSource media = session.OpenMedia(mediaPath);
            media.RenderFrameToFile(seconds, outPngPath);
            Console.WriteLine($"Wrote {outPngPath} ({media.Info.Width}x{media.Info.Height} @ {seconds:0.###}s)");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"--dump-frame failed: {ex.Message}");
            return 1;
        }
    }

    // <projectOrSnapshotPath> is either a .palmier package directory (built into a snapshot via
    // TimelineSnapshotBuilder, using ActiveTimelineId or the first timeline) or a timeline-
    // snapshot-v1 JSON file (docs/timeline-snapshot-v1.md) — a raw file on disk. As a convenience
    // for pointing this straight at the checked-in golden fixtures under tests/*/Fixtures/, a
    // literal "{{FIXTURE_DIR}}" token in the JSON is substituted with the snapshot file's own
    // directory (JSON-escaped) — mirrors TimelineCompositorTests.LoadTimelineSnapshotJson.
    private static int RunDumpTimelineFrame(string[] args)
    {
        if (args.Length != 4)
        {
            Console.Error.WriteLine(
                "usage: PalmierPro.DevHarness.exe --dump-timeline-frame <projectOrSnapshotPath> <frame> <outPngPath>");
            return 1;
        }
        string inputPath = args[1];
        string outPngPath = args[3];
        if (!long.TryParse(args[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out long frame))
        {
            Console.Error.WriteLine($"--dump-timeline-frame: invalid frame value '{args[2]}'");
            return 1;
        }

        try
        {
            byte[] snapshotJson = LoadSnapshotJson(inputPath, out int offlineCount);
            if (offlineCount > 0)
            {
                Console.Error.WriteLine($"--dump-timeline-frame: warning — {offlineCount} media ref(s) failed to resolve and were skipped");
            }

            using var session = new EngineSession();
            using PalmierPro.Rendering.TimelineSession timeline = PalmierPro.Rendering.TimelineSession.Open(session, snapshotJson);
            timeline.RenderFrameToFile(frame, outPngPath);
            Console.WriteLine($"Wrote {outPngPath} (timeline frame {frame})");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"--dump-timeline-frame failed: {ex.Message}");
            return 1;
        }
    }

    // Builds a synthetic two-clip (title over a stand-in video) timeline entirely in memory — no
    // real media needed, since FcpxmlExporter only checks a source file's existence/metadata, not
    // its contents — and exports it end to end through the real FfprobeSourceTimingReader (probing
    // the empty stand-in file, which fails soft to "no timecode") and DirectWriteFontTraitResolver
    // shims this stage introduced, demonstrating the exporters before the Export dialog (Stage F).
    private static int RunExportFcpxml(string[] args)
    {
        if (args.Length != 2)
        {
            Console.Error.WriteLine("usage: PalmierPro.DevHarness.exe --export-fcpxml <outFcpxmlPath>");
            return 1;
        }
        string outPath = args[1];
        string standInMedia = Path.Combine(Path.GetTempPath(), $"palmier-devharness-{Guid.NewGuid():N}.mp4");
        try
        {
            File.WriteAllBytes(standInMedia, []);
            var manifest = new MediaManifest
            {
                Entries =
                [
                    new MediaManifestEntry(
                        "clip-1", "clip-1", ClipType.Video, PalmierPro.Core.Models.MediaSource.External(standInMedia), duration: 5.0,
                        sourceWidth: 1920, sourceHeight: 1080, hasAudio: false),
                ],
            };
            var resolver = new MediaResolver(() => manifest, () => null);

            var video = new Clip("clip-1", 0, 90) { Id = SwiftId.New() };
            var title = new Clip("title", 0, 90)
            {
                Id = SwiftId.New(),
                MediaType = ClipType.Text,
                SourceClipType = ClipType.Text,
                TextContent = "PalmierPro",
                TextStyle = JsonSerializer.SerializeToElement(new TextStyle()),
            };
            var timeline = new Timeline
            {
                Fps = 30,
                Width = 1920,
                Height = 1080,
                Tracks =
                [
                    new Track(ClipType.Video, [title]),
                    new Track(ClipType.Video, [video]),
                ],
            };

            using var fontResolver = new DirectWriteFontTraitResolver();
            var timingReader = new FfprobeSourceTimingReader();
            FcpxmlExporter.ExportAsync(timeline, resolver, timingReader, fontResolver, outPath).GetAwaiter().GetResult();
            Console.WriteLine($"Wrote {outPath}");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"--export-fcpxml failed: {ex.Message}");
            return 1;
        }
        finally
        {
            try
            {
                File.Delete(standInMedia);
            }
            catch (IOException)
            {
                // Best effort — a lingering handle shouldn't fail the run.
            }
        }
    }

    private static byte[] LoadSnapshotJson(string inputPath, out int offlineCount)
    {
        if (Directory.Exists(inputPath))
        {
            ProjectPackageContents contents = ProjectPackageIO.Load(inputPath);
            string timelineId = contents.ProjectFile.ActiveTimelineId ?? contents.ProjectFile.Timelines[0].Id;
            var manifest = contents.Manifest ?? new MediaManifest();
            var resolver = new MediaResolver(() => manifest, () => inputPath);
            TimelineSnapshotBuildResult result = TimelineSnapshotBuilder.Build(contents.ProjectFile, timelineId, resolver);
            offlineCount = result.OfflineMediaRefs.Count;
            return TimelineSnapshotSerializer.ToJsonBytes(result.Snapshot);
        }

        if (!File.Exists(inputPath))
        {
            throw new FileNotFoundException($"No project package directory or snapshot JSON file at '{inputPath}'.", inputPath);
        }
        offlineCount = 0;
        string json = File.ReadAllText(inputPath);
        if (json.Contains("{{FIXTURE_DIR}}", StringComparison.Ordinal))
        {
            string fixtureDir = Path.GetDirectoryName(Path.GetFullPath(inputPath)) ?? ".";
            json = json.Replace("{{FIXTURE_DIR}}", fixtureDir.Replace("\\", "\\\\"));
        }
        return System.Text.Encoding.UTF8.GetBytes(json);
    }
}
