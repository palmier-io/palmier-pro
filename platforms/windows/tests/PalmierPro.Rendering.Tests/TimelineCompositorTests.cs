using System.Drawing;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// Exercises the E2 timeline ABI (PE_OpenTimeline/PE_TimelineSeek/PE_TimelineRenderFrameToFile)
// end to end against real ffmpeg-generated fixture media and the checked-in golden snapshot
// JSON under Fixtures/ — see docs/timeline-snapshot-v1.md for the schema and TimelineSession.cpp/
// Compositor.cpp for what's under test. PE_TimelineRenderFrameToFile is the synchronous golden
// hook (bypasses the render thread/mailbox), used here for every pixel-correctness assertion so
// results are deterministic; PE_TimelineSeek (the async/coalesced path) is exercised separately by
// the seek-storm test, which only asserts liveness/absence-of-deadlock plus a final synchronous
// render for correctness.
[Collection(MediaFixturesCollection.Name)]
public sealed class TimelineCompositorTests(MediaFixtures fixtures)
{
    // PE_SeekMode raw values (native/include/palmier_engine.h).
    private const int SeekExact = 0;
    private const int SeekInteractiveScrub = 1;

    private static string LoadTimelineSnapshotJson(string fixtureName, string fixtureDir) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", fixtureName))
            .Replace("{{FIXTURE_DIR}}", fixtureDir.Replace("\\", "\\\\"));

    private static string RenderToTempPng(TimelineSession timeline, long frame)
    {
        string path = Path.Combine(Path.GetTempPath(), $"palmier-timeline-{Guid.NewGuid():N}.png");
        timeline.RenderFrameToFile(frame, path);
        return path;
    }

    private static void AssertColorNear(Color actual, Color expected, int tolerance)
    {
        Math.Abs(actual.R - expected.R).ShouldBeLessThanOrEqualTo(tolerance, $"R: actual={actual} expected={expected}");
        Math.Abs(actual.G - expected.G).ShouldBeLessThanOrEqualTo(tolerance, $"G: actual={actual} expected={expected}");
        Math.Abs(actual.B - expected.B).ShouldBeLessThanOrEqualTo(tolerance, $"B: actual={actual} expected={expected}");
    }

    [Fact]
    [Trait("Category", "Media")]
    public void TwoTrackComposite_TopLayerCoversLeftHalf_BottomLayerVisibleOnRight()
    {
        using var session = new EngineSession();
        string json = LoadTimelineSnapshotJson("two-track.snapshot.json", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));

        string pngPath = RenderToTempPng(timeline, frame: 15);
        try
        {
            using var bitmap = new Bitmap(pngPath);
            bitmap.Width.ShouldBe(MediaFixtures.VideoWidth);
            bitmap.Height.ShouldBe(MediaFixtures.VideoHeight);

            // Top track (last in tracks[], per docs/timeline-snapshot-v1.md §2) is the RED clip,
            // transformed to cover only the left half of the canvas — the right half falls through
            // to the bottom (BLUE, full-canvas) track.
            Color leftPixel = bitmap.GetPixel(MediaFixtures.VideoWidth / 4, MediaFixtures.VideoHeight / 2);
            Color rightPixel = bitmap.GetPixel(MediaFixtures.VideoWidth * 3 / 4, MediaFixtures.VideoHeight / 2);

            AssertColorNear(leftPixel, Color.Red, tolerance: 12);
            AssertColorNear(rightPixel, Color.Blue, tolerance: 12);
        }
        finally
        {
            File.Delete(pngPath);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void MutedAudioTrack_ContributesNothingToVideoOutput()
    {
        using var session = new EngineSession();
        string json = LoadTimelineSnapshotJson("muted-audio-track.snapshot.json", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));

        string pngPath = RenderToTempPng(timeline, frame: 15);
        try
        {
            using var bitmap = new Bitmap(pngPath);
            for (int y = 0; y < bitmap.Height; y += 40)
            {
                for (int x = 0; x < bitmap.Width; x += 40)
                {
                    AssertColorNear(bitmap.GetPixel(x, y), Color.Blue, tolerance: 12);
                }
            }
        }
        finally
        {
            File.Delete(pngPath);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void OpacityHalf_BlendsRedOverBlue_WithinTolerance()
    {
        using var session = new EngineSession();
        string json = LoadTimelineSnapshotJson("opacity-half.snapshot.json", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));

        string pngPath = RenderToTempPng(timeline, frame: 15);
        try
        {
            using var bitmap = new Bitmap(pngPath);
            Color center = bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2);

            // FrameRenderer.applyClipPipeline fades ONLY the alpha channel of an already-
            // premultiplied layer (CIColorMatrix inputAVector=(0,0,0,alpha)) — premultiplied RGB
            // stays at full strength. That is NOT the same as the "conventional" premultiplied
            // fade (scale both RGB and alpha by opacity, which would give red@0.5 over blue =
            // (128,0,128)): source-over here still contributes the source's full red channel,
            // only its coverage (alpha) is halved, so blue shows through at 50% while red does
            // not itself dim. See Compositor.cpp's SourceOverAccumulate / Compositor.h.
            AssertColorNear(center, Color.FromArgb(255, 0, 128), tolerance: 10);
        }
        finally
        {
            File.Delete(pngPath);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void RetimedClip_Speed2_MatchesDirectSourceDecodeAtMappedTime()
    {
        using var session = new EngineSession();
        string json = LoadTimelineSnapshotJson("retimed-speed2.snapshot.json", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));

        // timeline frame 10, speed 2.0, trimStart 0, timeline fps 30 -> source seconds =
        // (0 + (10 - 0) * 2.0) / 30 — mirrors Compositor::SourceSeconds exactly.
        const long timelineFrame = 10;
        const double expectedSourceSeconds = (0 + (timelineFrame - 0) * 2.0) / 30.0;

        string composedPngPath = RenderToTempPng(timeline, timelineFrame);

        string directPngPath = Path.Combine(Path.GetTempPath(), $"palmier-direct-{Guid.NewGuid():N}.png");
        using (MediaSource direct = session.OpenMedia(fixtures.VideoWithAudioPath))
        {
            direct.RenderFrameToFile(expectedSourceSeconds, directPngPath);
        }

        try
        {
            using var composed = new Bitmap(composedPngPath);
            using var directBitmap = new Bitmap(directPngPath);
            composed.Width.ShouldBe(directBitmap.Width);
            composed.Height.ShouldBe(directBitmap.Height);

            // Sample a spread of points rather than every pixel — fp16 working-buffer rounding
            // (see Compositor.h's Color pipeline remarks) can shift a channel by a couple of
            // 8-bit levels even for an otherwise pixel-exact identity-transform, opacity-1 clip.
            for (int y = 10; y < composed.Height; y += 47)
            {
                for (int x = 10; x < composed.Width; x += 53)
                {
                    AssertColorNear(composed.GetPixel(x, y), directBitmap.GetPixel(x, y), tolerance: 6);
                }
            }
        }
        finally
        {
            File.Delete(composedPngPath);
            File.Delete(directPngPath);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task SeekStorm_100RapidInteractiveSeeks_CompletesWithoutDeadlock_AndFinalExactSeekRendersCorrectly()
    {
        using var session = new EngineSession();
        string json = LoadTimelineSnapshotJson("two-track.snapshot.json", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));

        var random = new Random(42);
        var stormTask = Task.Run(() =>
        {
            for (int i = 0; i < 100; i++)
            {
                long frame = random.Next(0, 60);
                timeline.Seek(frame, SeekInteractiveScrub);
            }
            timeline.Seek(15, SeekExact);
        });

        // PE_TimelineSeek never blocks on the render thread (enqueue-and-return) — 100 calls plus
        // one exact dispatch should complete near-instantly regardless of scrub-throttle timing.
        // A bounded wait here (rather than an unbounded await) is what actually catches a real
        // deadlock in CI instead of hanging the whole test run.
        Task completed = await Task.WhenAny(stormTask, Task.Delay(TimeSpan.FromSeconds(15)));
        completed.ShouldBe(stormTask, "PE_TimelineSeek storm should never block/deadlock");
        await stormTask; // propagate any exception from inside the storm task

        // Correctness check is via the synchronous golden hook, independent of whichever frame the
        // async render thread happened to land on mid-storm.
        string pngPath = RenderToTempPng(timeline, frame: 15);
        try
        {
            using var bitmap = new Bitmap(pngPath);
            AssertColorNear(bitmap.GetPixel(MediaFixtures.VideoWidth / 4, MediaFixtures.VideoHeight / 2), Color.Red, tolerance: 12);
            AssertColorNear(bitmap.GetPixel(MediaFixtures.VideoWidth * 3 / 4, MediaFixtures.VideoHeight / 2), Color.Blue, tolerance: 12);
        }
        finally
        {
            File.Delete(pngPath);
        }
    }
}
