using System.Drawing;
using System.Text;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// E3's Rebuild-vs-RefreshParams ABI split (PE_TimelineRefreshParams) — see
// docs/timeline-snapshot-v1.md §11 and TimelineSession::RefreshParams's media-set assertion.
[Collection(MediaFixturesCollection.Name)]
public sealed class RefreshParamsTests(MediaFixtures fixtures)
{
    private static string LoadTimelineSnapshotJson(string fixtureName, string fixtureDir) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", fixtureName))
            .Replace("{{FIXTURE_DIR}}", fixtureDir.Replace("\\", "\\\\"));

    private static string RenderToTempPng(TimelineSession timeline, long frame)
    {
        string path = Path.Combine(Path.GetTempPath(), $"palmier-refresh-{Guid.NewGuid():N}.png");
        timeline.RenderFrameToFile(frame, path);
        return path;
    }

    [Fact]
    [Trait("Category", "Media")]
    public void RefreshParams_ChangesLevelsParam_WithoutReopeningTheSession_AndRendersNewValue()
    {
        using var session = new EngineSession();
        string original = LoadTimelineSnapshotJson("levels-refresh-params.snapshot.json", fixtures.FixturesDir);
        // `timeline` is opened exactly ONCE for this whole test — the media handle/decoder
        // session it owns (native TimelineSession's mediaCache_) is never torn down or
        // recreated by RefreshParams (only Close/re-Open would do that); this identity —
        // one PE_OpenTimeline call, one native TimelineSession/MediaCache instance,
        // reused across both the "before" and "after" renders below — IS the observable
        // evidence that PE_TimelineRefreshParams did not rebuild the decoder.
        using TimelineSession timeline = TimelineSession.Open(session, Encoding.UTF8.GetBytes(original));

        string beforePath = RenderToTempPng(timeline, frame: 15);
        Color before;
        try
        {
            using var bitmap = new Bitmap(beforePath);
            before = bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2);
        }
        finally
        {
            File.Delete(beforePath);
        }
        // Identity params (blacks=0, whites=0) -> unchanged flat gray (0x808080 = 128).
        Math.Abs(before.R - 128).ShouldBeLessThanOrEqualTo(4);

        // whites: 0.0 -> 0.6. Levels.hlsl: wp = 1 - whites*0.4 = 0.76; bp = 0;
        // result = saturate(rgb / 0.76) = 0.50196/0.76 = 0.6605 -> 168/255.
        string patched = original.Replace(
            "\"whites\": { \"value\": 0.0, \"string\": null, \"keyframes\": null }",
            "\"whites\": { \"value\": 0.6, \"string\": null, \"keyframes\": null }");
        patched.ShouldNotBe(original, "the string replace must actually match the fixture's whites param");

        timeline.RefreshParams(Encoding.UTF8.GetBytes(patched));

        string afterPath = RenderToTempPng(timeline, frame: 15);
        try
        {
            using var bitmap = new Bitmap(afterPath);
            Color after = bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2);
            after.R.ShouldBeGreaterThan(before.R, "RefreshParams must actually take effect on the next render");
            Math.Abs(after.R - 168).ShouldBeLessThanOrEqualTo(6);
        }
        finally
        {
            File.Delete(afterPath);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void RefreshParams_RejectsAChangedMediaSet_AsAStructuralRebuild()
    {
        using var session = new EngineSession();
        string original = LoadTimelineSnapshotJson("levels-refresh-params.snapshot.json", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, Encoding.UTF8.GetBytes(original));

        // Swap the clip's media entirely — a structural change PE_TimelineRefreshParams must
        // refuse (native asserts the media path SET is unchanged; see palmier_engine.h).
        string structurallyChanged = original.Replace("solid_gray_640x360_30fps_2s.mp4", "solid_red_640x360_30fps_2s.mp4");
        structurallyChanged.ShouldNotBe(original);

        Should.Throw<EngineException>(() => timeline.RefreshParams(Encoding.UTF8.GetBytes(structurallyChanged)));

        // The session must still be usable afterwards (a rejected refresh must not corrupt the
        // still-open, still-valid snapshot).
        string pngPath = RenderToTempPng(timeline, frame: 15);
        try
        {
            using var bitmap = new Bitmap(pngPath);
            Math.Abs(bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2).R - 128).ShouldBeLessThanOrEqualTo(4);
        }
        finally
        {
            File.Delete(pngPath);
        }
    }
}
