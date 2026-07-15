using PalmierPro.Core.Models;
using PalmierPro.Services.Engine;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// E4.5 mix slice (docs/audio-playback-v1.md §6). Drives the offline mix hook
// (PE_TimelineRenderAudioRange → AudioMixer) end-to-end: build a real audio-track snapshot through
// the C# TimelineSnapshotBuilder/Serializer, open it natively, and mix a 48 kHz range straight into
// a float buffer — no XAudio2 device, so deterministic on a device-less CI runner. Uses the pinned
// 1 kHz sine fixture (MediaFixtures.AudioOnlyPath) so the expected amplitudes are exact.
[Collection(MediaFixturesCollection.Name)]
public sealed class TimelineAudioMixerTests(MediaFixtures fixtures)
{
    private const int Fps = 30;
    private const int MixRate = 48000;
    private const int ClipDurationFrames = 60; // the 2 s fixture, whole

    // Builds a one-audio-track timeline referencing the sine fixture, run through the real
    // builder + serializer exactly as the app does, and opens it natively.
    private TimelineSession OpenSine(EngineSession session, double volume, int fadeInFrames, bool muted)
    {
        var clip = new Clip("sine", startFrame: 0, durationFrames: ClipDurationFrames)
        {
            Id = "CLIP-A",
            MediaType = ClipType.Audio,
            SourceClipType = ClipType.Audio,
            Volume = volume,
            FadeInFrames = fadeInFrames,
        };
        var track = new Track(ClipType.Audio, [clip]) { Id = "TRACK-A", Muted = muted };
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

    private static float Peak(float[] interleaved, int start, int count)
    {
        float peak = 0f;
        int end = Math.Min(interleaved.Length, (start + count) * 2);
        for (int i = start * 2; i < end; i++)
        {
            peak = Math.Max(peak, Math.Abs(interleaved[i]));
        }
        return peak;
    }

    [Fact]
    [Trait("Category", "Media")]
    public void RenderAudioRange_GainHalf_YieldsHalfAmplitude()
    {
        using var session = new EngineSession();

        float fullPeak;
        using (TimelineSession full = OpenSine(session, volume: 1.0, fadeInFrames: 0, muted: false))
        {
            fullPeak = Peak(full.RenderAudioRange(startFrame: 0, frameCount: MixRate), 0, MixRate);
        }

        float halfPeak;
        using (TimelineSession half = OpenSine(session, volume: 0.5, fadeInFrames: 0, muted: false))
        {
            halfPeak = Peak(half.RenderAudioRange(startFrame: 0, frameCount: MixRate), 0, MixRate);
        }

        // The sine actually decoded and mixed (guards against an all-silent false pass). The pinned
        // fixture is a -18 dB (~0.125 linear) mono sine, duplicated to L/R at unity per docs §1.
        fullPeak.ShouldBeGreaterThan(0.1f);
        fullPeak.ShouldBeLessThan(0.2f);
        // gain 0.5 halves the amplitude — the core linear-gain contract (docs §1).
        (halfPeak / fullPeak).ShouldBeInRange(0.45f, 0.55f);
    }

    [Fact]
    [Trait("Category", "Media")]
    public void RenderAudioRange_FadeIn_RampsUpFromSilence()
    {
        using var session = new EngineSession();
        // 1 s (30-frame) linear fade-in over a 1 s render — gain climbs 0 -> 1 across the range.
        using TimelineSession timeline = OpenSine(session, volume: 1.0, fadeInFrames: 30, muted: false);

        float[] mix = timeline.RenderAudioRange(startFrame: 0, frameCount: MixRate);

        // Peaks over five evenly spaced 4800-sample windows must climb monotonically as the fade
        // opens; the first window starts at true silence, the last is near full amplitude.
        const int window = 4800;
        float[] peaks = new float[5];
        for (int w = 0; w < 5; w++)
        {
            peaks[w] = Peak(mix, w * (MixRate / 5), window);
        }

        peaks[0].ShouldBeLessThan(0.2f);            // opens at (near) silence — gain ~0 at frame 0
        for (int w = 1; w < 5; w++)
        {
            peaks[w].ShouldBeGreaterThan(peaks[w - 1]); // strictly rising ramp
        }
        // Fully open by the end of the fade — far louder than the near-silent opening (relative so
        // the assertion holds whatever the fixture's absolute amplitude turns out to be).
        peaks[4].ShouldBeGreaterThan(peaks[0] * 4f);
    }

    [Fact]
    [Trait("Category", "Media")]
    public void RenderAudioRange_MutedTrack_IsSilent()
    {
        using var session = new EngineSession();
        using TimelineSession timeline = OpenSine(session, volume: 1.0, fadeInFrames: 0, muted: true);

        float[] mix = timeline.RenderAudioRange(startFrame: 0, frameCount: MixRate);

        // A muted track is skipped whole (docs §6.1) — the bus is bit-exact silence.
        Peak(mix, 0, MixRate).ShouldBe(0f);
    }
}
