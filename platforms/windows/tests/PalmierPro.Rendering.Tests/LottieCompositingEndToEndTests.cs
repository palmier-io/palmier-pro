using System.Drawing;
using PalmierPro.Core.Models;
using PalmierPro.Services.Engine;
using PalmierPro.Services.Media;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// docs/lottie-bake-v1.md §14's end-to-end bullet, full stack: a real LottieBakeService (real
// ThorVG rasterize + real prores_ks 4444 encode, native/LottieBaker.cpp) bakes the checked-in
// Fixtures/lottie-shape-move.json fixture; TimelineSnapshotBuilder.Build carries the cached .mov
// into an ordinary SnapshotClip once it's ready; the real native TimelineSession composites it —
// over a distinctly-colored background track, so a pixel where the Lottie's rectangle is absent
// reads the BACKGROUND's color only if alpha is genuinely respected during compositing (not
// silently forced opaque/black). The fixture's 40x40 red (`[1,0,0,1]`) square is keyframed from
// layer-position (20,50) at frame 0 to (80,50) at frame 29 inside a 100x100 comp — i.e. it spans
// comp-x [0,40] at frame 0 and [60,100] at frame 29 (both times comp-y [30,70]) — so sampling one
// point inside/outside that span at both frames proves both alpha compositing AND frame-accurate
// animation sampling survived bake -> encode -> decode -> composite.
[Collection(MediaFixturesCollection.Name)]
public sealed class LottieCompositingEndToEndTests(MediaFixtures fixtures)
{
    private const int CanvasSize = 100; // matches the fixture's own authored "w"/"h" — no scaling ambiguity
    private static string FixturePath => Path.Combine(AppContext.BaseDirectory, "Fixtures", "lottie-shape-move.json");

    private static TimelineSnapshotBuildResult BuildSnapshot(ProjectFile project, MediaResolver resolver, ILottieBakeService bakeService) =>
        TimelineSnapshotBuilder.Build(project, "TL-1", resolver, bakeService);

    private static (ProjectFile Project, MediaResolver Resolver) MakeProject(string lottiePath, string grayPath)
    {
        var backgroundClip = new Clip("gray", 0, 30) { Id = "BG-CLIP", MediaType = ClipType.Video, SourceClipType = ClipType.Video };
        var lottieClip = new Clip("lottie-shape", 0, 30) { Id = "LOTTIE-CLIP", MediaType = ClipType.Lottie, SourceClipType = ClipType.Lottie };
        var bgTrack = new Track(ClipType.Video, [backgroundClip]) { Id = "BG-TRACK" };
        var lottieTrack = new Track(ClipType.Video, [lottieClip]) { Id = "LOTTIE-TRACK" };
        // Timeline.Tracks index 0 = topmost/frontmost (§2) — the Lottie track must be index 0 so it
        // paints OVER the background, not under it.
        var timeline = new Timeline { Id = "TL-1", Fps = 30, Width = CanvasSize, Height = CanvasSize, Tracks = [lottieTrack, bgTrack] };
        var project = new ProjectFile([timeline], timeline.Id, [timeline.Id]);
        var manifest = new MediaManifest
        {
            Entries =
            [
                new MediaManifestEntry("gray", "gray", ClipType.Video, PalmierPro.Core.Models.MediaSource.External(grayPath), duration: 10),
                new MediaManifestEntry("lottie-shape", "lottie-shape", ClipType.Lottie, PalmierPro.Core.Models.MediaSource.External(lottiePath), duration: 1),
            ],
        };
        return (project, new MediaResolver(() => manifest, () => null));
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task LottieClip_BakesOnFirstBuild_ThenCompositesWithAlphaOverBackground_AndSkipsRebakeOnCacheHit()
    {
        string cacheDir = Path.Combine(Path.GetTempPath(), $"palmier-lottie-e2e-{Guid.NewGuid():N}");
        try
        {
            using var session = new EngineSession();
            var bakeService = new LottieBakeService(session, new DiskCache("lottie", cacheDir));
            int inProgressCount = 0;
            var completed = new TaskCompletionSource<LottieBakeStatusChangedEventArgs>();
            bakeService.StatusChanged += (_, e) =>
            {
                if (e.Status == LottieBakeStatus.InProgress)
                {
                    Interlocked.Increment(ref inProgressCount);
                }
                else if (e.Status is LottieBakeStatus.Completed or LottieBakeStatus.Failed)
                {
                    completed.TrySetResult(e);
                }
            };

            var (project, resolver) = MakeProject(FixturePath, fixtures.GrayClipPath);

            // ----- Build #1: cold cache -> clip skipped, pending, bake kicked off -----
            TimelineSnapshotBuildResult first = BuildSnapshot(project, resolver, bakeService);
            first.OfflineMediaRefs.ShouldBeEmpty();
            first.PendingLottieBakes.ShouldBe(["lottie-shape"]);
            SnapshotTrack? lottieTrackInFirst = first.Snapshot.Tracks.FirstOrDefault(t => t.Id == "LOTTIE-TRACK");
            lottieTrackInFirst.ShouldBeNull("a not-yet-baked Lottie clip contributes nothing to tracks[] — doc §10");

            LottieBakeStatusChangedEventArgs completion = await completed.Task.WaitAsync(TimeSpan.FromSeconds(60));
            completion.Status.ShouldBe(LottieBakeStatus.Completed, completion.ErrorMessage);
            string bakedPath = completion.OutputPath.ShouldNotBeNull();
            File.Exists(bakedPath).ShouldBeTrue();

            // ----- Build #2: cache hit -> ordinary Type=Video SnapshotClip, no second bake -----
            TimelineSnapshotBuildResult second = BuildSnapshot(project, resolver, bakeService);
            second.PendingLottieBakes.ShouldBeEmpty();
            SnapshotClip lottieSnapshotClip = second.Snapshot.Tracks.Single(t => t.Id == "LOTTIE-TRACK").Clips.ShouldHaveSingleItem();
            lottieSnapshotClip.Type.ShouldBe(ClipType.Video, "a baked Lottie clip is an ordinary video clip downstream — doc §10");
            lottieSnapshotClip.MediaPath.ShouldBe(bakedPath);
            inProgressCount.ShouldBe(1, "a cache hit on the second Build() must not trigger a second native bake");

            byte[] json = TimelineSnapshotSerializer.ToJsonBytes(second.Snapshot);
            using TimelineSession nativeTimeline = TimelineSession.Open(session, json);

            AssertPixel(nativeTimeline, frame: 0, x: 20, y: 50, Color.FromArgb(255, 0, 0), "frame 0: the fixture's red square covers comp-x [0,40] here");
            AssertPixel(nativeTimeline, frame: 0, x: 90, y: 50, Color.FromArgb(128, 128, 128), "frame 0: outside the square — the gray background must show through the Lottie clip's transparent region");
            AssertPixel(nativeTimeline, frame: 29, x: 90, y: 50, Color.FromArgb(255, 0, 0), "frame 29: the square has moved to comp-x [60,100] here");
            AssertPixel(nativeTimeline, frame: 29, x: 20, y: 50, Color.FromArgb(128, 128, 128), "frame 29: the square has moved away — background shows through again");
        }
        finally
        {
            try
            {
                Directory.Delete(cacheDir, recursive: true);
            }
            catch (IOException)
            {
            }
        }
    }

    private static void AssertPixel(TimelineSession timeline, long frame, int x, int y, Color expected, string because)
    {
        string path = Path.Combine(Path.GetTempPath(), $"palmier-lottie-e2e-frame-{Guid.NewGuid():N}.png");
        try
        {
            timeline.RenderFrameToFile(frame, path);
            using var bitmap = new Bitmap(path);
            Color actual = bitmap.GetPixel(x, y);
            AssertColorNear(actual, expected, tolerance: 24, because);
        }
        finally
        {
            File.Delete(path);
        }
    }

    private static void AssertColorNear(Color actual, Color expected, int tolerance, string because)
    {
        Math.Abs(actual.R - expected.R).ShouldBeLessThanOrEqualTo(tolerance, $"{because} (R: expected ~{expected.R}, got {actual.R})");
        Math.Abs(actual.G - expected.G).ShouldBeLessThanOrEqualTo(tolerance, $"{because} (G: expected ~{expected.G}, got {actual.G})");
        Math.Abs(actual.B - expected.B).ShouldBeLessThanOrEqualTo(tolerance, $"{because} (B: expected ~{expected.B}, got {actual.B})");
    }
}
