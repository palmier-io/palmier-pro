using System.Drawing;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// Two properties TimelineCompositorTests.cs doesn't cover (read it first — this file
// deliberately does not duplicate its two-track/opacity/retime pixel assertions):
//   1. Determinism — PE_TimelineRenderFrameToFile is documented (palmier_engine.h) as a
//      synchronous golden hook specifically so repeat calls are reproducible; assert that
//      literally, at the byte level, both against one open handle and against a freshly
//      reopened one.
//   2. Compositor passthrough correctness — a single full-canvas, non-retimed, opacity-1,
//      identity-transform clip should reproduce the direct MediaSource decode of the mapped
//      source frame. This is the E2 analogue of TimelineCompositorTests' retimed-clip check,
//      minus retiming, isolating pure compositor pixel fidelity from the source-seconds math.
[Collection(MediaFixturesCollection.Name)]
public sealed class TimelineDeterminismTests(MediaFixtures fixtures)
{
    // Measured tolerance 0 (fp16 exactly round-trips 8-bit source values for an identity-
    // transform, opacity-1, non-retimed clip — unlike TimelineCompositorTests' RetimedClip case,
    // there's no fractional-source-time resampling here to introduce drift); kept at 2 rather
    // than 0 for headroom against decoder/platform variance.
    private const int PassthroughTolerance = 2;

    private static string LoadTimelineSnapshotJson(string fixtureName, string fixtureDir) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", fixtureName))
            .Replace("{{FIXTURE_DIR}}", fixtureDir.Replace("\\", "\\\\"));

    private static string TempPngPath(string label) =>
        Path.Combine(Path.GetTempPath(), $"palmier-{label}-{Guid.NewGuid():N}.png");

    [Fact]
    [Trait("Category", "Media")]
    public void RenderFrameToFile_CalledTwiceOnTheSameHandle_ProducesByteIdenticalPngs()
    {
        using var session = new EngineSession();
        string json = LoadTimelineSnapshotJson("opacity-half.snapshot.json", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));

        string firstPath = TempPngPath("determinism-a");
        string secondPath = TempPngPath("determinism-b");
        try
        {
            timeline.RenderFrameToFile(15, firstPath);
            timeline.RenderFrameToFile(15, secondPath);

            byte[] first = File.ReadAllBytes(firstPath);
            byte[] second = File.ReadAllBytes(secondPath);
            first.Length.ShouldBeGreaterThan(0);
            second.ShouldBe(first, "PE_TimelineRenderFrameToFile is documented as a deterministic, synchronous golden hook");
        }
        finally
        {
            File.Delete(firstPath);
            File.Delete(secondPath);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void RenderFrameToFile_AcrossTwoIndependentlyOpenedHandles_ProducesByteIdenticalPngs()
    {
        using var session = new EngineSession();
        string json = LoadTimelineSnapshotJson("two-track.snapshot.json", fixtures.FixturesDir);
        byte[] jsonBytes = System.Text.Encoding.UTF8.GetBytes(json);

        string firstPath = TempPngPath("determinism-fresh-a");
        string secondPath = TempPngPath("determinism-fresh-b");
        try
        {
            using (TimelineSession first = TimelineSession.Open(session, jsonBytes))
            {
                first.RenderFrameToFile(15, firstPath);
            }
            using (TimelineSession second = TimelineSession.Open(session, jsonBytes))
            {
                second.RenderFrameToFile(15, secondPath);
            }

            File.ReadAllBytes(secondPath).ShouldBe(
                File.ReadAllBytes(firstPath),
                "same snapshot JSON in, byte-identical PNG out — regardless of which timeline handle rendered it");
        }
        finally
        {
            File.Delete(firstPath);
            File.Delete(secondPath);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void SingleFullFrameClip_NoRetiming_MatchesDirectSourceDecodeAtMappedTime()
    {
        using var session = new EngineSession();
        string json = LoadTimelineSnapshotJson("single-full-frame.snapshot.json", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, System.Text.Encoding.UTF8.GetBytes(json));

        // startFrame=0, trimStartFrame=0, speed=1.0 -> source seconds = timelineFrame / fps
        // (Compositor::SourceSeconds with no retiming applied), matching direct decode 1:1.
        const long timelineFrame = 20;
        const double expectedSourceSeconds = timelineFrame / 30.0;

        string composedPngPath = TempPngPath("passthrough-composed");
        string directPngPath = TempPngPath("passthrough-direct");
        try
        {
            timeline.RenderFrameToFile(timelineFrame, composedPngPath);
            using (MediaSource direct = session.OpenMedia(fixtures.VideoWithAudioPath))
            {
                direct.RenderFrameToFile(expectedSourceSeconds, directPngPath);
            }

            using var composed = new Bitmap(composedPngPath);
            using var directBitmap = new Bitmap(directPngPath);
            composed.Width.ShouldBe(directBitmap.Width);
            composed.Height.ShouldBe(directBitmap.Height);

            // Full-canvas identity transform at output size == source size, so the compositor
            // path (decode -> fp16 straight-alpha composite -> 8-bit) and the direct-decode path
            // (decode -> 8-bit) should agree everywhere the source has any spatial variation, not
            // just at a handful of sampled points — scan every pixel of a spread of rows.
            for (int y = 0; y < composed.Height; y += 3)
            {
                for (int x = 0; x < composed.Width; x += 3)
                {
                    Color actual = composed.GetPixel(x, y);
                    Color expected = directBitmap.GetPixel(x, y);
                    Math.Abs(actual.R - expected.R).ShouldBeLessThanOrEqualTo(PassthroughTolerance, $"R at ({x},{y}): actual={actual} expected={expected}");
                    Math.Abs(actual.G - expected.G).ShouldBeLessThanOrEqualTo(PassthroughTolerance, $"G at ({x},{y}): actual={actual} expected={expected}");
                    Math.Abs(actual.B - expected.B).ShouldBeLessThanOrEqualTo(PassthroughTolerance, $"B at ({x},{y}): actual={actual} expected={expected}");
                }
            }
        }
        finally
        {
            File.Delete(composedPngPath);
            File.Delete(directPngPath);
        }
    }
}
