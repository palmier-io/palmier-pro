using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using Shouldly;
using Xunit;
using Xunit.Abstractions;

namespace PalmierPro.Rendering.Tests;

// Deliverable "scrub responsiveness harness check" (Stage B done bar: "a speed-changed clip
// scrub correctly in the harness") as an automated, CI-covered measurement rather than a
// manual-only one — a human dragging DevHarness's Timeline page slider issues the exact same
// PE_TimelineSeek(InteractiveScrub) calls this test issues in a loop (see TimelinePage.xaml.cs's
// SeekBoth/OnEnginePlayheadChanged, which measure latency the same way: time from Seek issuance
// to the next PlayheadChanged callback). Prints p50/p95/max via ITestOutputHelper so `dotnet test`
// output carries real measured numbers, not just a pass/fail.
[Collection(MediaFixturesCollection.Name)]
public sealed class ScrubLatencyTests(MediaFixtures fixtures, ITestOutputHelper output)
{
    private const int SeekExact = 0;
    private const int SeekInteractiveScrub = 1;
    private const int BurstCount = 150;

    [Fact]
    [Trait("Category", "Media")]
    public void InteractiveScrubBurst_SeekToPresentLatencyStaysResponsive()
    {
        using var session = new EngineSession();
        string json = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "two-track.snapshot.json"))
            .Replace("{{FIXTURE_DIR}}", fixtures.FixturesDir.Replace("\\", "\\\\"));
        using TimelineSession timeline = TimelineSession.Open(session, Encoding.UTF8.GetBytes(json));

        var latenciesMs = new ConcurrentQueue<double>();
        long lastIssuedTimestamp = 0;
        using var settled = new ManualResetEventSlim();
        const int finalFrame = 30;

        timeline.PlayheadChanged += frame =>
        {
            long issued = Interlocked.Read(ref lastIssuedTimestamp);
            if (issued != 0)
            {
                latenciesMs.Enqueue(Stopwatch.GetElapsedTime(issued).TotalMilliseconds);
            }
            if (frame == finalFrame)
            {
                settled.Set();
            }
        };

        // ~60 Hz simulated pointer-move cadence (faster than the native ~30 Hz coalescing
        // throttle — see palmier_engine.h's "Threading" remarks) so some of these genuinely
        // coalesce, the same way a real mouse drag does.
        var random = new Random(1234);
        for (int i = 0; i < BurstCount; i++)
        {
            int frame = random.Next(0, 60);
            Interlocked.Exchange(ref lastIssuedTimestamp, Stopwatch.GetTimestamp());
            timeline.Seek(frame, SeekInteractiveScrub);
            Thread.Sleep(16);
        }
        Interlocked.Exchange(ref lastIssuedTimestamp, Stopwatch.GetTimestamp());
        timeline.Seek(finalFrame, SeekExact);

        settled.Wait(TimeSpan.FromSeconds(5)).ShouldBeTrue("final exact seek should settle within 5s");

        double[] values = [.. latenciesMs];
        values.Length.ShouldBeGreaterThan(0, "the render thread should have composed at least one frame during the burst");
        Array.Sort(values);
        double p50 = values[values.Length / 2];
        double p95 = values[(int)((values.Length - 1) * 0.95)];
        double max = values[^1];
        output.WriteLine(
            $"scrub burst: {BurstCount} interactive seeks + 1 exact -> {values.Length} composed frames; " +
            $"seek->present latency p50={p50:0.0}ms p95={p95:0.0}ms max={max:0.0}ms");

        // A sanity bound, not a tight perf-regression gate (CI hardware varies widely) — this
        // guards against the render thread stalling/deadlocking under load, not against day-to-day
        // jitter. Real-world scrub feel is governed by the ~30Hz coalescing throttle itself.
        p95.ShouldBeLessThan(500, "p95 seek->present latency should stay well under human-perceptible lag even under a synthetic burst");
    }
}
