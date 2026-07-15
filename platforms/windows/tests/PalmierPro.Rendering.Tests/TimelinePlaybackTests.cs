using PalmierPro.Core.Models;
using PalmierPro.Services.Engine;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// E4.5 clock/present slice (docs/audio-playback-v1.md §3, §4). Drives PE_TimelinePlay/Pause/Seek/
// GetClockFrame end to end against a real 2 s fixture, headless (no swap chain). On a device-less
// CI runner this is the QPC software-clock path (doc §3.4); either way playback must advance the
// clock monotonically, fire the playhead per presented frame, auto-stop at the timeline duration,
// and rebase forward on a seek issued mid-play. The audio-clock (SamplesPlayed) math itself is
// asserted separately and device-free by PlaybackClockSelfTests.
[Collection(MediaFixturesCollection.Name)]
public sealed class TimelinePlaybackTests(MediaFixtures fixtures)
{
    private const int Fps = 30;
    private const int DurationFrames = 60; // the 2 s fixture, whole
    private const int SeekExact = 0;

    // Builds a one-audio-track timeline over the pinned 2 s sine, through the real builder +
    // serializer exactly as the app does, and opens it natively. Audio-only on purpose: this slice
    // tests the clock + present-scheduling, so composing a black frame (no video decode) keeps the
    // test focused and off the video-decode path. On a device it still drives the real audio clock
    // (the voice plays the sine, SamplesPlayed advances); on a device-less runner it is the QPC path.
    private TimelineSession OpenClip(EngineSession session)
    {
        var clip = new Clip("sine", startFrame: 0, durationFrames: DurationFrames)
        {
            Id = "CLIP-A",
            MediaType = ClipType.Audio,
            SourceClipType = ClipType.Audio,
        };
        var track = new Track(ClipType.Audio, [clip]) { Id = "TRACK-A" };
        var timeline = new Timeline
        {
            Id = "TL-P", Fps = Fps, Width = MediaFixtures.VideoWidth, Height = MediaFixtures.VideoHeight,
            Tracks = [track],
        };
        var project = new ProjectFile([timeline], timeline.Id, [timeline.Id]);
        var manifest = new MediaManifest
        {
            Entries = [new MediaManifestEntry("sine", "sine", ClipType.Audio,
                PalmierPro.Core.Models.MediaSource.External(fixtures.AudioOnlyPath), duration: DurationFrames)],
        };
        var resolver = new MediaResolver(() => manifest, () => null);

        var result = TimelineSnapshotBuilder.Build(project, "TL-P", resolver);
        byte[] json = TimelineSnapshotSerializer.ToJsonBytes(result.Snapshot);
        return TimelineSession.Open(session, json);
    }

    [Fact]
    [Trait("Category", "Media")]
    public void Play_AdvancesPlayheadMonotonically_AndAutoStopsAtDuration()
    {
        using var session = new EngineSession();
        using TimelineSession timeline = OpenClip(session);

        var playhead = new List<long>();
        var playheadLock = new object();
        using var stopped = new ManualResetEventSlim(false);

        timeline.PlayheadChanged += frame =>
        {
            lock (playheadLock)
            {
                playhead.Add(frame);
            }
        };
        timeline.IsPlayingChanged += isPlaying =>
        {
            if (!isPlaying)
            {
                stopped.Set();
            }
        };

        // A freshly opened timeline is paused at frame 0 (doc §3.2).
        timeline.GetClockFrame().ShouldBe(0L);

        timeline.Play();

        // The 2 s timeline plays in ~2 s of wall time on either clock; the engine auto-stops itself
        // at the duration boundary and raises IsPlayingChanged(false) — wait for that, generously.
        stopped.Wait(TimeSpan.FromSeconds(10)).ShouldBeTrue("playback did not auto-stop at end of timeline");

        // Frozen exactly at the duration boundary after auto-stop (doc §3.5).
        timeline.GetClockFrame().ShouldBe((long)DurationFrames);

        long[] frames;
        lock (playheadLock)
        {
            frames = [.. playhead];
        }

        // The present loop actually ran and scheduled frames.
        frames.Length.ShouldBeGreaterThan(10);
        // Monotonic non-decreasing — the clock never runs backwards during playback.
        for (int i = 1; i < frames.Length; i++)
        {
            frames[i].ShouldBeGreaterThanOrEqualTo(frames[i - 1]);
        }
        // Started at/near 0 and reached the duration boundary.
        frames[0].ShouldBeLessThan(10L);
        frames[^1].ShouldBeInRange(DurationFrames - 2L, DurationFrames);
    }

    [Fact]
    [Trait("Category", "Media")]
    public void SeekMidPlay_RebasesClockForward_AndKeepsPlaying()
    {
        using var session = new EngineSession();
        using TimelineSession timeline = OpenClip(session);

        timeline.Play();
        Thread.Sleep(150); // ~4-5 frames in

        long beforeSeek = timeline.GetClockFrame();
        beforeSeek.ShouldBeLessThan(30L); // nowhere near the seek target yet

        // Seek forward while playing: rebases the clock to 45 and playback CONTINUES (does not
        // implicitly pause — doc §3.3).
        timeline.Seek(45, SeekExact);
        Thread.Sleep(120);

        long afterSeek = timeline.GetClockFrame();
        afterSeek.ShouldBeGreaterThanOrEqualTo(45L); // rebased forward to the seek target...
        afterSeek.ShouldBeLessThan((long)DurationFrames); // ...and still short of the end
        afterSeek.ShouldBeGreaterThan(beforeSeek);

        timeline.Pause();
        long paused = timeline.GetClockFrame();
        Thread.Sleep(60);
        // Frozen after Pause — the clock does not advance while paused (doc §3.2).
        timeline.GetClockFrame().ShouldBe(paused);
    }

    // Device-gated (docs/audio-playback-v1.md §3.4): only meaningful on a runner with a real audio
    // endpoint — the QPC→audio-clock handover is unreachable device-less (PlaybackClockSelfTests
    // covers the pure clock math there). Soft-skips when no device flips the clock on the first play.
    // Guards the regression where the audio master clock never re-engaged after the first Play:
    // XAudio2 SamplesPlayed on the persistent voice is cumulative and does NOT reset on Start, so the
    // second Play's confirmation must be "played advanced past the pre-Start baseline," not "played
    // dropped below it." Without the fix the clock stays stuck on QPC for the rest of the session.
    [Fact]
    [Trait("Category", "Audio")]
    public void ReplayAfterPause_ReengagesAudioClock()
    {
        using var session = new EngineSession();
        using TimelineSession timeline = OpenClip(session);

        timeline.Play();
        if (!WaitForAudioClock(timeline, TimeSpan.FromSeconds(2)))
        {
            // Device-less runner: the first play never leaves QPC, so this hardware-only path can't
            // be exercised here. Nothing to assert.
            return;
        }

        // Freeze mid-clip, then play again from where it froze.
        timeline.Pause();
        timeline.GetClockFrame().ShouldBeLessThan((long)DurationFrames); // not at the end yet

        timeline.Play();
        WaitForAudioClock(timeline, TimeSpan.FromSeconds(2))
            .ShouldBeTrue("audio master clock did not re-engage the audio path after pause -> play");

        timeline.Pause();
    }

    // Polls UsingAudioClock() until it reports the sample-locked audio path or the timeout elapses.
    private static bool WaitForAudioClock(TimelineSession timeline, TimeSpan timeout)
    {
        DateTime deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (timeline.UsingAudioClock())
            {
                return true;
            }
            Thread.Sleep(20);
        }
        return timeline.UsingAudioClock();
    }

    [Fact]
    [Trait("Category", "Media")]
    public void SetRate_AcceptsZeroAndOne_RejectsAnythingElse()
    {
        using var session = new EngineSession();
        using TimelineSession timeline = OpenClip(session);

        // v1 accepts only 0.0 (paused) / 1.0 (playing) — anything else is PE_ERROR_INVALID_ARGUMENT
        // (a loud reject, never a silent clamp — doc §4).
        Should.Throw<EngineException>(() => timeline.SetRate(0.5));
        Should.Throw<EngineException>(() => timeline.SetRate(2.0));
        Should.Throw<EngineException>(() => timeline.SetRate(-1.0));

        timeline.SetRate(1.0); // play
        timeline.SetRate(0.0); // pause
        timeline.GetClockFrame().ShouldBeLessThan((long)DurationFrames);
    }
}
