using PalmierPro.Services.Engine;
using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests.Engine;

/// Pure-logic tests for the VideoEngine.swift interactive-scrub coalescing port. `schedule` is
/// injected as "call back immediately" so these run with no real wall-clock waits.
public class SeekCoordinatorTests
{
    private static SeekCoordinator ImmediateCoordinator(Action<int, TimeSpan> onSeek, Func<DateTime>? now = null) =>
        new(onSeek, now, schedule: (_, callback) => callback());

    [Theory]
    [InlineData(1, 0.15)]
    [InlineData(2, 0.30)]
    [InlineData(5, 0.75)] // capped
    [InlineData(10, 0.75)] // still capped
    [InlineData(0, 0.15)] // max(1, …) floors the count at 1
    public void InteractiveToleranceMatchesMacFormula(int activeLayers, double expectedSeconds)
    {
        SeekCoordinator.InteractiveTolerance(activeLayers).TotalSeconds.ShouldBe(expectedSeconds, tolerance: 1e-9);
    }

    [Fact]
    public void ExactModeBypassesCoalescingAndDispatchesImmediately()
    {
        var calls = new List<(int Frame, TimeSpan Tolerance)>();
        var coordinator = ImmediateCoordinator((f, t) => calls.Add((f, t)));

        coordinator.Seek(42, PreviewSeekMode.Exact, activeVideoLayerCount: 3);

        calls.ShouldBe([(42, TimeSpan.Zero)]);
    }

    [Fact]
    public void ExactSeekCancelsAPendingInteractiveScrub()
    {
        var calls = new List<int>();
        var now = DateTime.UtcNow;
        var scheduled = new List<Action>();
        var coordinator = new SeekCoordinator((f, _) => calls.Add(f), () => now, (_, cb) => scheduled.Add(cb));

        // The very first InteractiveScrub always dispatches immediately (nothing dispatched yet
        // means the throttle window is trivially elapsed) — establish that baseline first so the
        // SECOND scrub genuinely lands inside the throttle window and gets scheduled/pending.
        coordinator.Seek(1, PreviewSeekMode.InteractiveScrub, activeVideoLayerCount: 1);
        calls.ShouldBe([1]);

        coordinator.Seek(10, PreviewSeekMode.InteractiveScrub, activeVideoLayerCount: 1); // scheduled, pending
        coordinator.Seek(99, PreviewSeekMode.Exact, activeVideoLayerCount: 1); // cancels the pending scrub, dispatches now
        calls.ShouldBe([1, 99]);

        foreach (var cb in scheduled)
        {
            cb(); // simulate the timer(s) firing after the cancel
        }

        // The cancelled interactive seek never dispatches when its timer eventually fires.
        calls.ShouldBe([1, 99]);
    }

    [Fact]
    public void InteractiveScrubDispatchesImmediatelyWhenThrottleWindowAlreadyElapsed()
    {
        var calls = new List<(int Frame, TimeSpan Tolerance)>();
        var now = DateTime.UtcNow;
        var coordinator = new SeekCoordinator((f, t) => calls.Add((f, t)), () => now, (_, _) => throw new InvalidOperationException("should not schedule"));

        coordinator.Seek(5, PreviewSeekMode.InteractiveScrub, activeVideoLayerCount: 1);

        calls.ShouldHaveSingleItem();
        calls[0].Frame.ShouldBe(5);
        calls[0].Tolerance.ShouldBe(SeekCoordinator.InteractiveTolerance(1));
    }

    [Fact]
    public void RapidInteractiveScrubsWithinTheThrottleWindowCoalesceToLatestWins()
    {
        var calls = new List<int>();
        var now = DateTime.UtcNow;
        Action? pendingFlush = null;
        var coordinator = new SeekCoordinator(
            (f, _) => calls.Add(f),
            () => now,
            (_, cb) => pendingFlush = cb); // capture instead of firing — simulates "still within the 30Hz window"

        coordinator.Seek(1, PreviewSeekMode.InteractiveScrub, activeVideoLayerCount: 1);
        // First call scheduled (not dispatched yet, since it's the initial call with lastDispatch
        // at MinValue... but MinValue means "way in the past", so delay <= 0 and it dispatches
        // immediately). Advance the mock clock so a SECOND call is genuinely inside the window.
        calls.ShouldBe([1]);

        coordinator.Seek(2, PreviewSeekMode.InteractiveScrub, activeVideoLayerCount: 1); // scheduled, not dispatched
        coordinator.Seek(3, PreviewSeekMode.InteractiveScrub, activeVideoLayerCount: 1); // coalesces onto the same pending flush
        calls.ShouldBe([1]); // still just the first — 2 and 3 are pending, latest-wins

        pendingFlush.ShouldNotBeNull();
        pendingFlush();

        calls.ShouldBe([1, 3]); // flush dispatches the LATEST pending frame (3), not 2
    }

    [Fact]
    public async Task DefaultScheduleSurvivesGarbageCollectionBeforeItFires()
    {
        // Regression: the default (real Timer) schedule must keep its Timer rooted until it
        // fires. An un-rooted System.Threading.Timer is eligible for GC — its finalizer cancels
        // the pending callback — so a coalesced scrub seek could silently vanish. Force a
        // collection right after scheduling to catch a Timer that isn't kept alive.
        //
        // The FIRST Seek always dispatches synchronously (lastDispatch starts at DateTime.MinValue,
        // so the throttle window is trivially elapsed) — it must not be what this test waits on, or
        // it'd pass even with the pre-fix bug (the second, timer-based dispatch just silently never
        // happening). Only the SECOND call's dispatch actually exercises DefaultSchedule's Timer.
        var secondDispatched = new TaskCompletionSource<int>();
        var dispatchCount = 0;
        var coordinator = new SeekCoordinator((f, _) =>
        {
            if (Interlocked.Increment(ref dispatchCount) == 2)
            {
                secondDispatched.TrySetResult(f);
            }
        }); // real clock + DefaultSchedule

        coordinator.Seek(1, PreviewSeekMode.InteractiveScrub, activeVideoLayerCount: 1); // dispatches immediately, seeds lastDispatch
        coordinator.Seek(2, PreviewSeekMode.InteractiveScrub, activeVideoLayerCount: 1); // lands inside the 30Hz window -> real Timer scheduled

        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();

        var completed = await Task.WhenAny(secondDispatched.Task, Task.Delay(TimeSpan.FromSeconds(2)));
        completed.ShouldBe(secondDispatched.Task, "the scheduled flush never fired — the Timer was likely collected before it could run");
        int frame = await secondDispatched.Task;
        frame.ShouldBe(2);
    }

    [Fact]
    public void CancelPendingDropsAnAlreadyScheduledFlush()
    {
        var calls = new List<int>();
        var now = DateTime.UtcNow;
        Action? pendingFlush = null;
        var coordinator = new SeekCoordinator((f, _) => calls.Add(f), () => now, (_, cb) => pendingFlush = cb);

        coordinator.Seek(1, PreviewSeekMode.InteractiveScrub, activeVideoLayerCount: 1); // dispatches immediately (MinValue lastDispatch)
        coordinator.Seek(2, PreviewSeekMode.InteractiveScrub, activeVideoLayerCount: 1); // scheduled
        coordinator.CancelPending();
        pendingFlush!.Invoke();

        calls.ShouldBe([1]); // the scheduled flush fired, but found nothing pending
    }
}
