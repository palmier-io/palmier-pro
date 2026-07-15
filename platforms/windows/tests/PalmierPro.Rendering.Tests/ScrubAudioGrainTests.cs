using PalmierPro.Core.Models;
using PalmierPro.Services.Engine;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// E4.5 scrub slice (docs/audio-playback-v1.md §5, §9 "scrub"). Drives the offline golden hook
// (PE_TimelineRenderScrubGrain → ScrubAudio::RenderGrain) end-to-end: build a real audio-track
// snapshot through the C# TimelineSnapshotBuilder/Serializer, open it natively, and grab a
// windowed grain — no XAudio2 device, so deterministic on a device-less CI runner. Uses the
// pinned 1 kHz sine fixture (MediaFixtures.AudioOnlyPath) so the expected amplitude is exact.
[Collection(MediaFixturesCollection.Name)]
public sealed class ScrubAudioGrainTests(MediaFixtures fixtures)
{
    private const int Fps = 30;
    private const int ClipDurationFrames = 60; // the 2 s fixture, whole

    // Mirrors ScrubAudio::kGrainFrameCount / kFadeFrameCount (native/ScrubAudio.h) — not shared
    // across the P/Invoke boundary, so pinned here the same way TimelineAudioMixerTests pins
    // MixRate.
    private const int GrainFrameCount = 2400;
    private const int FadeFrameCount = 144;

    private TimelineSession OpenSine(EngineSession session)
    {
        var clip = new Clip("sine", startFrame: 0, durationFrames: ClipDurationFrames)
        {
            Id = "CLIP-A",
            MediaType = ClipType.Audio,
            SourceClipType = ClipType.Audio,
            Volume = 1.0,
        };
        var track = new Track(ClipType.Audio, [clip]) { Id = "TRACK-A" };
        var timeline = new Timeline
        {
            Id = "TL-A", Fps = Fps, Width = MediaFixtures.VideoWidth, Height = MediaFixtures.VideoHeight,
            Tracks = [track],
        };
        var project = new ProjectFile([timeline], timeline.Id, [timeline.Id]);
        var manifest = new MediaManifest
        {
            Entries = [new MediaManifestEntry("sine", "sine", ClipType.Audio,
                PalmierPro.Core.Models.MediaSource.External(fixtures.AudioOnlyPath), duration: ClipDurationFrames)],
        };
        var resolver = new MediaResolver(() => manifest, () => null);

        var result = TimelineSnapshotBuilder.Build(project, "TL-A", resolver);
        result.OfflineMediaRefs.ShouldBeEmpty();
        byte[] json = TimelineSnapshotSerializer.ToJsonBytes(result.Snapshot);
        return TimelineSession.Open(session, json);
    }

    private static float PeakStereo(float[] interleaved, int startFrame, int count)
    {
        float peak = 0f;
        int end = Math.Min(interleaved.Length, (startFrame + count) * 2);
        for (int i = startFrame * 2; i < end; i++)
        {
            peak = Math.Max(peak, Math.Abs(interleaved[i]));
        }
        return peak;
    }

    [Fact]
    [Trait("Category", "Media")]
    public void RenderScrubGrain_Center_MatchesSineFixtureAmplitude()
    {
        using var session = new EngineSession();
        using TimelineSession timeline = OpenSine(session);

        // 1.5 s into the 2 s clip — well clear of both clip edges, so the grain's edge fade is
        // the only attenuation at play.
        float[] grain = timeline.RenderScrubGrain(frame: 45, TimelineSession.ScrubForward, GrainFrameCount);

        // Middle third of the grain sits outside the ~3 ms (144-sample) edge ramps at both ends.
        int middleStart = GrainFrameCount / 3;
        int middleCount = GrainFrameCount / 3;
        float centerPeak = PeakStereo(grain, middleStart, middleCount);

        // Same -18 dB (~0.125 linear) pinned fixture amplitude TimelineAudioMixerTests asserts —
        // confirms real sine content was decoded, not silence.
        centerPeak.ShouldBeGreaterThan(0.1f);
        centerPeak.ShouldBeLessThan(0.2f);

        // The very first/last samples sit inside the edge fade's opening ramp (edgeGain(0) =
        // 1/144) — far quieter than the unfaded center, confirming the fade is actually applied.
        float firstSamplePeak = PeakStereo(grain, 0, 1);
        firstSamplePeak.ShouldBeLessThan(centerPeak * 0.05f);
        float lastSamplePeak = PeakStereo(grain, GrainFrameCount - 1, 1);
        lastSamplePeak.ShouldBeLessThan(centerPeak * 0.05f);
    }

    [Fact]
    [Trait("Category", "Media")]
    public void RenderScrubGrain_Reverse_MirrorsForwardGrain()
    {
        using var session = new EngineSession();
        using TimelineSession timeline = OpenSine(session);

        float[] forward = timeline.RenderScrubGrain(frame: 45, TimelineSession.ScrubForward, GrainFrameCount);
        float[] reverse = timeline.RenderScrubGrain(frame: 45, TimelineSession.ScrubReverse, GrainFrameCount);

        // The edge-fade envelope is symmetric under index -> (N - 1 - index), so reversing
        // direction is exactly equivalent to reading the forward grain backwards — an analytic
        // identity independent of the fixture's actual waveform shape (docs/audio-playback-v1.md
        // §5; mirrors ScrubAudioEngine.makeGrain's forward/reverse source-sample selection).
        for (int j = 0; j < GrainFrameCount; j++)
        {
            int mirrored = GrainFrameCount - 1 - j;
            reverse[j * 2 + 0].ShouldBe(forward[mirrored * 2 + 0], tolerance: 1e-5);
            reverse[j * 2 + 1].ShouldBe(forward[mirrored * 2 + 1], tolerance: 1e-5);
        }

        // Not a trivially-all-zero pass: the middle of the grain must carry real signal.
        PeakStereo(reverse, GrainFrameCount / 3, GrainFrameCount / 3).ShouldBeGreaterThan(0.1f);
    }

    [Fact]
    [Trait("Category", "Media")]
    public void RenderScrubGrain_NearTimelineStart_LeadingEdgeIsSilent()
    {
        using var session = new EngineSession();
        using TimelineSession timeline = OpenSine(session);

        // Frame 0's window is centered at sample 0, so the first half (samples before 0) has no
        // source content at all — silence, not a crash or garbage read (mirrors
        // ScrubAudioEngine.makeGrain's own out-of-window-bounds silence, doc §5).
        float[] grain = timeline.RenderScrubGrain(frame: 0, TimelineSession.ScrubForward, GrainFrameCount);

        PeakStereo(grain, 0, GrainFrameCount / 2 - FadeFrameCount).ShouldBe(0f);
        // The back half (real content, still ramping up via the fade) is not silent.
        PeakStereo(grain, GrainFrameCount / 2, GrainFrameCount / 4).ShouldBeGreaterThan(0f);
    }
}
