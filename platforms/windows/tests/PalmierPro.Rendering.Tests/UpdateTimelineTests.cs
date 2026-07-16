using System.Text;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// PE_UpdateTimeline (docs/timeline-snapshot-v1.md §11's Rebuild half) — structural edits like a
// clip-speed change (TimelineEditorViewModel.ApplyClipSpeed -> NotifyTimelineChanged -> Update) go
// through this path rather than PE_TimelineRefreshParams.
[Collection(MediaFixturesCollection.Name)]
public sealed class UpdateTimelineTests(MediaFixtures fixtures)
{
    private static string LoadTimelineSnapshotJson(string fixtureName, string fixtureDir) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", fixtureName))
            .Replace("{{FIXTURE_DIR}}", fixtureDir.Replace("\\", "\\\\"));

    // Same regression seam as RefreshParamsTests's paused-edit test, exercised through Update()
    // instead: TimelineSession::Update also swaps snapshot_ without notifying the render thread's
    // mailbox (see TimelineSession::NudgePresentIfPaused), so a paused structural edit — clip speed
    // being the running example in practice — left the pre-edit frame on screen until the next
    // Seek/Play. PlayheadChanged fires from the render thread's own compose+present, so it is
    // observable headlessly (no swap chain needed).
    [Fact]
    [Trait("Category", "Media")]
    public void Update_WhilePaused_WakesTheRenderThreadAndRePresentsTheCurrentFrame()
    {
        const int SeekExact = 0;
        using var session = new EngineSession();
        string original = LoadTimelineSnapshotJson("levels-refresh-params.snapshot.json", fixtures.FixturesDir);
        using TimelineSession timeline = TimelineSession.Open(session, Encoding.UTF8.GetBytes(original));

        var playheadEvents = new List<long>();
        var playheadLock = new object();
        using var gotFirst = new ManualResetEventSlim(false);
        using var gotSecond = new ManualResetEventSlim(false);
        timeline.PlayheadChanged += frame =>
        {
            lock (playheadLock)
            {
                playheadEvents.Add(frame);
                if (playheadEvents.Count == 1)
                {
                    gotFirst.Set();
                }
                else if (playheadEvents.Count == 2)
                {
                    gotSecond.Set();
                }
            }
        };

        // Establish a baseline presented frame while paused.
        timeline.Seek(15, SeekExact);
        gotFirst.Wait(TimeSpan.FromSeconds(5)).ShouldBeTrue("the baseline seek never composed");

        string patched = original.Replace("\"speed\": 1.0", "\"speed\": 2.0");
        patched.ShouldNotBe(original, "the string replace must actually match the fixture's clip speed");

        timeline.Update(Encoding.UTF8.GetBytes(patched));

        gotSecond.Wait(TimeSpan.FromSeconds(5)).ShouldBeTrue(
            "Update while paused must itself wake the render thread to recompose+present against " +
            "the new snapshot, not leave the pre-edit frame on screen until the next Seek/Play");

        lock (playheadLock)
        {
            playheadEvents.Count.ShouldBe(2);
            // The nudge re-presents the SAME frame — a structural param edit never moves the playhead.
            playheadEvents[1].ShouldBe(playheadEvents[0]);
        }
    }
}
