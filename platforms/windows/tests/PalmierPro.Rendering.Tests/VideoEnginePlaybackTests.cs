using PalmierPro.Core.Models;
using PalmierPro.Services.Engine;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// E4.5 "infra" C# slice (docs/audio-playback-v1.md §7): VideoEngine.Play/Pause/SetRate/IsPlaying
// and their event marshalling — PlayheadChanged carrying the right TimelineId, IsPlayingChanged
// firing for explicit calls AND the engine's own auto-stop, and the per-timeline IsPlaying
// dictionary not cross-contaminating between sessions. TimelinePlaybackTests already covers the
// native clock/present-loop correctness directly against TimelineSession; this suite instead
// drives the Services-layer VideoEngine through the same real (CI-safe, device-less-tolerant)
// engine, so the C# marshalling on top of it is proven end to end.
[Collection(MediaFixturesCollection.Name)]
public sealed class VideoEnginePlaybackTests(MediaFixtures fixtures)
{
    private const int Fps = 30;
    private const int DurationFrames = 60; // the 2 s fixture, whole

    // Audio-only, mirroring TimelinePlaybackTests.OpenClip — this suite tests VideoEngine's C#
    // bookkeeping, not video decode, so a black-frame-free audio track keeps it focused.
    private TimelineSnapshotBuildResult BuildSnapshot(string timelineId)
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
            Id = timelineId, Fps = Fps, Width = MediaFixtures.VideoWidth, Height = MediaFixtures.VideoHeight,
            Tracks = [track],
        };
        var project = new ProjectFile([timeline], timeline.Id, [timeline.Id]);
        var manifest = new MediaManifest
        {
            Entries = [new MediaManifestEntry("sine", "sine", ClipType.Audio,
                PalmierPro.Core.Models.MediaSource.External(fixtures.AudioOnlyPath), duration: DurationFrames)],
        };
        var resolver = new MediaResolver(() => manifest, () => null);
        return TimelineSnapshotBuilder.Build(project, timelineId, resolver);
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task IsPlaying_DefaultsFalse_ForUnopenedAndFreshlyOpenedTimeline()
    {
        using var engine = new VideoEngine();
        engine.IsPlaying("nonexistent-tl").ShouldBeFalse();

        await engine.OpenTimelineSessionAsync("TL-A", BuildSnapshot("TL-A"));
        engine.IsPlaying("TL-A").ShouldBeFalse();
    }

    [Fact]
    [Trait("Category", "Media")]
    public void Play_Pause_SetRate_OnUnopenedTimeline_ThrowInvalidOperationException()
    {
        using var engine = new VideoEngine();
        Should.Throw<InvalidOperationException>(() => engine.Play("nonexistent-tl"));
        Should.Throw<InvalidOperationException>(() => engine.Pause("nonexistent-tl"));
        Should.Throw<InvalidOperationException>(() => engine.SetRate("nonexistent-tl", 1.0));
    }

    [Fact]
    [Trait("Category", "Media")]
    public void SetRate_RejectsInvalidRate_ClientSide_BeforeTouchingSession()
    {
        using var engine = new VideoEngine();
        // Fails on the invalid value itself even with no open session for the timeline — proves
        // the {0.0, 1.0} check runs before GetOpenTimelineOrThrow, not after a native round-trip.
        Should.Throw<ArgumentOutOfRangeException>(() => engine.SetRate("nonexistent-tl", 0.5));
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task Play_SetsIsPlayingImmediately_AndFiresIsPlayingChanged()
    {
        using var engine = new VideoEngine();
        await engine.OpenTimelineSessionAsync("TL-A", BuildSnapshot("TL-A"));

        var raised = new List<bool>();
        var raisedLock = new object();
        engine.IsPlayingChanged += (_, isPlaying) =>
        {
            lock (raisedLock)
            {
                raised.Add(isPlaying);
            }
        };

        engine.Play("TL-A");
        engine.IsPlaying("TL-A").ShouldBeTrue();
        lock (raisedLock)
        {
            raised.ShouldContain(true);
        }

        engine.Pause("TL-A");
        engine.IsPlaying("TL-A").ShouldBeFalse();
        lock (raisedLock)
        {
            raised[^1].ShouldBeFalse();
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task IsPlaying_IsPerTimeline_PlayingOneDoesNotAffectAnother()
    {
        using var engine = new VideoEngine();
        await engine.OpenTimelineSessionAsync("TL-A", BuildSnapshot("TL-A"));
        await engine.OpenTimelineSessionAsync("TL-B", BuildSnapshot("TL-B"));

        engine.Play("TL-A");
        try
        {
            engine.IsPlaying("TL-A").ShouldBeTrue();
            engine.IsPlaying("TL-B").ShouldBeFalse();
        }
        finally
        {
            engine.Pause("TL-A");
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task PlayheadChanged_CarriesCorrectTimelineId()
    {
        using var engine = new VideoEngine();
        await engine.OpenTimelineSessionAsync("TL-A", BuildSnapshot("TL-A"));

        var seen = new List<PlayheadChangedEventArgs>();
        var seenLock = new object();
        engine.PlayheadChanged += (_, e) =>
        {
            lock (seenLock)
            {
                seen.Add(e);
            }
        };

        engine.Seek("TL-A", 10, PreviewSeekMode.Exact);
        // Native's own render-thread callback — give it a moment to actually compose and fire.
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(5);
        while (DateTime.UtcNow < deadline)
        {
            lock (seenLock)
            {
                if (seen.Count > 0)
                {
                    break;
                }
            }
            await Task.Delay(25);
        }

        List<PlayheadChangedEventArgs> snapshot;
        lock (seenLock)
        {
            snapshot = [.. seen];
        }
        snapshot.ShouldNotBeEmpty();
        snapshot.ShouldAllBe(e => e.TimelineId == "TL-A");
    }

    [Fact]
    [Trait("Category", "Media")]
    public async Task Play_AutoStopAtDuration_UpdatesIsPlayingViaEngineCallback()
    {
        using var engine = new VideoEngine();
        await engine.OpenTimelineSessionAsync("TL-A", BuildSnapshot("TL-A"));

        using var stopped = new ManualResetEventSlim(false);
        engine.IsPlayingChanged += (_, isPlaying) =>
        {
            if (!isPlaying)
            {
                stopped.Set();
            }
        };

        engine.Play("TL-A");
        // The 2 s fixture auto-stops itself at the duration boundary (docs/audio-playback-v1.md
        // §3.5) — IsPlayingChanged must fire through VideoEngine, not just TimelineSession.
        stopped.Wait(TimeSpan.FromSeconds(10)).ShouldBeTrue("auto-stop never reached VideoEngine.IsPlayingChanged");
        engine.IsPlaying("TL-A").ShouldBeFalse();
    }
}
