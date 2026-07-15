using PalmierPro.App.Tests.ViewModels.Editor;
using PalmierPro.App.ViewModels.Preview;
using PalmierPro.Services.Engine;
using Shouldly;
using Xunit;

namespace PalmierPro.App.Tests.ViewModels.Preview;

/// Ports the ViewModel-level slice of transport controls + playhead sync (M4, Stage D): the
/// play/pause state machine (including graceful degrade when `IVideoEngine.Play`/`Pause` throw
/// `InvalidOperationException` because no engine session is open yet for the active timeline — see
/// docs/audio-playback-v1.md), step/skip frame math, and the engine↔UI sync-loop guard (no feedback
/// loop between `PlayheadChanged` and `Seek`).
/// `dispatch`/`scheduleSettle` are injected as synchronous ("call immediately") throughout, mirroring
/// `SeekCoordinatorTests`' own "inject a synchronous scheduler" pattern, so these run with no real
/// wall-clock waits and no `DispatcherQueue`.
public class TransportViewModelTests
{
    private static async Task<(TransportViewModel Transport, TransportFakeVideoEngine Engine, TempDirectory Temp)> MakeAsync(int durationFrames = 300)
    {
        var (vm, temp) = await EditorFixtures.MakeAsync(tracks:
        [
            EditorFixtures.VideoTrack(clips: [EditorFixtures.Clip(start: 0, duration: durationFrames)]),
        ]);
        var engine = new TransportFakeVideoEngine();
        var transport = new TransportViewModel(
            vm,
            engine,
            dispatch: action => action(),
            scheduleSettle: (_, callback) => callback());
        return (transport, engine, temp);
    }

    // MARK: - Play/pause state machine

    [Fact]
    public async Task TogglePlayback_WhenPaused_PlaysAndTracksState()
    {
        var (transport, engine, temp) = await MakeAsync();
        using var _ = temp;

        transport.TogglePlayback();

        transport.IsPlaying.ShouldBeTrue();
        engine.PlayCalls.ShouldBe([transport.Timeline.ActiveTimelineId]);
    }

    [Fact]
    public async Task TogglePlayback_WhenPlaying_PausesAndTracksState()
    {
        var (transport, engine, temp) = await MakeAsync();
        using var _ = temp;
        transport.TogglePlayback(); // now playing

        transport.TogglePlayback();

        transport.IsPlaying.ShouldBeFalse();
        engine.PauseCalls.ShouldBe([transport.Timeline.ActiveTimelineId]);
    }

    [Fact]
    public async Task Play_WhenNoSessionOpenYet_LeavesIsPlayingFalse()
    {
        var (transport, engine, temp) = await MakeAsync();
        using var _ = temp;
        engine.PlayPauseThrowsNoSession = true;

        transport.Play();

        transport.IsPlaying.ShouldBeFalse();
    }

    [Fact]
    public async Task Pause_AlwaysLeavesIsPlayingFalseEvenIfEngineThrows()
    {
        var (transport, engine, temp) = await MakeAsync();
        using var _ = temp;
        engine.PlayPauseThrowsNoSession = true;

        transport.Pause();

        transport.IsPlaying.ShouldBeFalse();
    }

    // MARK: - Step / skip math (keyboard — audible-step mode, pause-first)

    [Fact]
    public async Task StepForward_AdvancesOneFrameWithAudibleStepMode()
    {
        var (transport, engine, temp) = await MakeAsync();
        using var _ = temp;
        transport.Timeline.CurrentFrame = 10;
        engine.SeekCalls.Clear();

        transport.StepForward();

        transport.Timeline.CurrentFrame.ShouldBe(11);
        engine.SeekCalls.ShouldBe([(transport.Timeline.ActiveTimelineId, 11, PreviewSeekMode.AudibleStepForward)]);
    }

    [Fact]
    public async Task StepBackward_ClampsAtZero()
    {
        var (transport, engine, temp) = await MakeAsync();
        using var _ = temp;
        transport.Timeline.CurrentFrame = 0;
        engine.SeekCalls.Clear();

        transport.StepBackward();

        transport.Timeline.CurrentFrame.ShouldBe(0);
        engine.SeekCalls.ShouldBe([(transport.Timeline.ActiveTimelineId, 0, PreviewSeekMode.AudibleStepBackward)]);
    }

    [Fact]
    public async Task SkipForward_DefaultsToFiveFrames()
    {
        var (transport, engine, temp) = await MakeAsync();
        using var _ = temp;
        transport.Timeline.CurrentFrame = 10;
        engine.SeekCalls.Clear();

        transport.SkipForward();

        transport.Timeline.CurrentFrame.ShouldBe(15);
        engine.SeekCalls.ShouldBe([(transport.Timeline.ActiveTimelineId, 15, PreviewSeekMode.AudibleStepForward)]);
    }

    [Fact]
    public async Task SkipBackward_ClampsAtZero()
    {
        var (transport, engine, temp) = await MakeAsync();
        using var _ = temp;
        transport.Timeline.CurrentFrame = 2;
        engine.SeekCalls.Clear();

        transport.SkipBackward();

        transport.Timeline.CurrentFrame.ShouldBe(0);
    }

    [Fact]
    public async Task StepForward_WhenPlaying_PausesFirst()
    {
        var (transport, engine, temp) = await MakeAsync();
        using var _ = temp;
        transport.TogglePlayback(); // now playing

        transport.StepForward();

        transport.IsPlaying.ShouldBeFalse();
        engine.PauseCalls.ShouldBe([transport.Timeline.ActiveTimelineId]);
    }

    // MARK: - Transport-bar buttons (exact mode, no pause-first)

    [Fact]
    public async Task SeekToStart_SeeksExactToFrameZero()
    {
        var (transport, engine, temp) = await MakeAsync();
        using var _ = temp;
        transport.Timeline.CurrentFrame = 42;
        engine.SeekCalls.Clear();

        transport.SeekToStart();

        transport.Timeline.CurrentFrame.ShouldBe(0);
        engine.SeekCalls.ShouldBe([(transport.Timeline.ActiveTimelineId, 0, PreviewSeekMode.Exact)]);
    }

    [Fact]
    public async Task SeekToEnd_SeeksExactToTotalFrames()
    {
        var (transport, engine, temp) = await MakeAsync(durationFrames: 300);
        using var _ = temp;
        engine.SeekCalls.Clear();

        transport.SeekToEnd();

        transport.Timeline.CurrentFrame.ShouldBe(300);
        engine.SeekCalls.ShouldBe([(transport.Timeline.ActiveTimelineId, 300, PreviewSeekMode.Exact)]);
    }

    [Fact]
    public async Task FrameStepForward_UsesExactModeNotAudibleStep()
    {
        var (transport, engine, temp) = await MakeAsync();
        using var _ = temp;
        transport.Timeline.CurrentFrame = 10;
        engine.SeekCalls.Clear();

        transport.FrameStepForward();

        engine.SeekCalls.ShouldBe([(transport.Timeline.ActiveTimelineId, 11, PreviewSeekMode.Exact)]);
    }

    // MARK: - Self-initiated seeks don't double-dispatch through the CurrentFrame-changed forwarder

    [Fact]
    public async Task StepForward_DispatchesExactlyOneSeekCall()
    {
        var (transport, engine, temp) = await MakeAsync();
        using var _ = temp;

        transport.StepForward();

        engine.SeekCalls.Count.ShouldBe(1);
    }

    // MARK: - Engine -> UI (no feedback loop between PlayheadChanged and Seek)

    [Fact]
    public async Task EnginePlayheadChanged_ForActiveTimeline_UpdatesCurrentFrameWithoutReseeking()
    {
        var (transport, engine, temp) = await MakeAsync();
        using var _ = temp;
        var timelineId = transport.Timeline.ActiveTimelineId;

        engine.RaisePlayheadChanged(timelineId, 77);

        transport.Timeline.CurrentFrame.ShouldBe(77);
        engine.SeekCalls.ShouldBeEmpty(); // the CurrentFrame write above must not loop back into Seek
    }

    [Fact]
    public async Task EnginePlayheadChanged_ForDifferentTimeline_IsIgnored()
    {
        var (transport, engine, temp) = await MakeAsync();
        using var _ = temp;
        transport.Timeline.CurrentFrame = 5;

        engine.RaisePlayheadChanged("some-other-timeline", 999);

        transport.Timeline.CurrentFrame.ShouldBe(5);
    }

    [Fact]
    public async Task EngineIsPlayingChanged_UpdatesIsPlayingProperty()
    {
        var (transport, engine, temp) = await MakeAsync();
        using var _ = temp;

        engine.RaiseIsPlayingChanged(true);
        transport.IsPlaying.ShouldBeTrue();

        engine.RaiseIsPlayingChanged(false);
        transport.IsPlaying.ShouldBeFalse();
    }

    // MARK: - UI -> engine (timeline scrub/click/local arrow keys applying straight to CurrentFrame)

    [Fact]
    public async Task ExternalCurrentFrameChange_ForwardsInteractiveScrubSeek()
    {
        var (transport, engine, temp) = await MakeAsync();
        using var _ = temp;

        // Mirrors TimelineCanvasControl.SeekToFrame/ScrubToScreenX writing CurrentFrame directly —
        // TransportViewModel never called, so this is an "external" change from its perspective.
        transport.Timeline.CurrentFrame = 123;

        engine.SeekCalls.ShouldContain((transport.Timeline.ActiveTimelineId, 123, PreviewSeekMode.InteractiveScrub));
    }

    [Fact]
    public async Task ExternalCurrentFrameChange_AlsoCommitsAnExactSeekOnSettle()
    {
        var (transport, engine, temp) = await MakeAsync();
        using var _ = temp;

        transport.Timeline.CurrentFrame = 123;

        // scheduleSettle is injected as "call immediately" — the settle-commit fires synchronously.
        engine.SeekCalls.ShouldContain((transport.Timeline.ActiveTimelineId, 123, PreviewSeekMode.Exact));
    }

    [Fact]
    public async Task Dispose_UnsubscribesFromEngineEvents()
    {
        var (transport, engine, temp) = await MakeAsync();
        using var _ = temp;

        transport.Dispose();
        engine.RaisePlayheadChanged(transport.Timeline.ActiveTimelineId, 55);

        transport.Timeline.CurrentFrame.ShouldNotBe(55);
    }
}
