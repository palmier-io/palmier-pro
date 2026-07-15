using PalmierPro.Core.Models;
using PalmierPro.Services.Engine;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// E4.5 retime slice (docs/audio-playback-v1.md §6 step 2, §9 "retime"). Drives the offline mix
// hook (PE_TimelineRenderAudioRange → AudioMixer → RetimeStretcher) with a speed != 1.0 clip and
// checks the two properties a pitch-preserving (as opposed to naive-resample, pitch-shifting)
// stretch must have: the output stays the same dominant frequency as an unsped render, and the
// on-timeline duration mapping (Clip.SourceFramesConsumed = DurationFrames × Speed, Timeline.cs:254)
// is exactly what the compositor already uses for video (Compositor.cpp:112-114).
[Collection(MediaFixturesCollection.Name)]
public sealed class RetimeStretcherTests(MediaFixtures fixtures)
{
    private const int Fps = 30;
    private const int MixRate = 48000;
    private const int FullSourceDurationFrames = 60; // the 2 s sine fixture, whole, at 30 fps

    // Builds a one-audio-track timeline with a single clip over the sine fixture at the given
    // speed/on-timeline duration, run through the real builder + serializer, opened natively.
    private TimelineSession OpenSine(EngineSession session, double speed, int durationFrames)
    {
        var clip = new Clip("sine", startFrame: 0, durationFrames: durationFrames)
        {
            Id = "CLIP-RETIME",
            MediaType = ClipType.Audio,
            SourceClipType = ClipType.Audio,
            Speed = speed,
        };
        var track = new Track(ClipType.Audio, [clip]) { Id = "TRACK-RETIME" };
        var timeline = new Timeline
        {
            Id = "TL-RETIME", Fps = Fps, Width = MediaFixtures.VideoWidth, Height = MediaFixtures.VideoHeight,
            Tracks = [track],
        };
        var project = new ProjectFile([timeline], timeline.Id, [timeline.Id]);
        var manifest = new MediaManifest
        {
            Entries = [new MediaManifestEntry("sine", "sine", ClipType.Audio,
                PalmierPro.Core.Models.MediaSource.External(fixtures.AudioOnlyPath), duration: FullSourceDurationFrames)],
        };
        var resolver = new MediaResolver(() => manifest, () => null);

        var result = TimelineSnapshotBuilder.Build(project, "TL-RETIME", resolver);
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

    // Left-channel zero-crossing count over `count` sample-frames starting at `start` — a
    // frequency proxy that doesn't need the stretcher's exact sample-for-sample output, only that
    // it oscillates at the same rate as the reference.
    private static int CountZeroCrossings(float[] interleaved, int start, int count)
    {
        int crossings = 0;
        float prev = interleaved[start * 2];
        int end = Math.Min(interleaved.Length / 2, start + count);
        for (int i = start + 1; i < end; i++)
        {
            float cur = interleaved[i * 2];
            if ((prev < 0f) != (cur < 0f))
            {
                crossings++;
            }
            prev = cur;
        }
        return crossings;
    }

    [Fact]
    [Trait("Category", "Media")]
    public void RenderAudioRange_DoubleSpeed_PreservesPitchAndHalvesDuration()
    {
        using var session = new EngineSession();

        // Reference: speed 1.0, clip spans the full 60-frame (2 s) fixture on the timeline. The
        // first 48,000 output samples are 1 s of an unmodified 1 kHz sine.
        int referenceCrossings;
        using (TimelineSession reference = OpenSine(session, speed: 1.0, durationFrames: FullSourceDurationFrames))
        {
            float[] mix = reference.RenderAudioRange(startFrame: 0, frameCount: MixRate);
            Peak(mix, 0, MixRate).ShouldBeGreaterThan(0.01f); // sanity: not silently failing to decode
            referenceCrossings = CountZeroCrossings(mix, 0, MixRate);
        }

        // 2x speed: halving DurationFrames (30 vs. 60) makes SourceFramesConsumed (Timeline.cs:254)
        // land on exactly the same 60 frames / 2 s of source audio as the reference clip above —
        // just mapped onto a 30-frame (1 s) timeline span instead of 60. Rendering that whole span
        // (frameCount == MixRate, one second) pulls the entire fixture through the stretcher.
        using (TimelineSession doubled = OpenSine(session, speed: 2.0, durationFrames: FullSourceDurationFrames / 2))
        {
            float[] wholeSpan = doubled.RenderAudioRange(startFrame: 0, frameCount: MixRate);
            Peak(wholeSpan, 0, MixRate).ShouldBeGreaterThan(0.01f);
            int doubledCrossings = CountZeroCrossings(wholeSpan, 0, MixRate);

            // Same dominant frequency as 1x (pitch preserved) — not the ~2x crossing count a naive
            // resample-to-speed would produce by playing the source back faster.
            double ratio = (double)doubledCrossings / referenceCrossings;
            ratio.ShouldBeInRange(0.85, 1.15);

            // Half duration: this clip ends at timeline frame 30 (1 s), so frame 45 — well within
            // the 1x clip's 60-frame span — is past this one's end. No covering clip -> silence
            // (docs §6.1), the direct, testable consequence of the duration mapping actually having
            // taken effect rather than being ignored.
            float[] pastEnd = doubled.RenderAudioRange(startFrame: 45, frameCount: 4800);
            Peak(pastEnd, 0, 4800).ShouldBe(0f);
        }
    }

    [Fact]
    [Trait("Category", "Media")]
    public void RenderAudioRange_HalfSpeed_PreservesPitchAndDoublesDuration()
    {
        using var session = new EngineSession();

        int referenceCrossings;
        using (TimelineSession reference = OpenSine(session, speed: 1.0, durationFrames: FullSourceDurationFrames))
        {
            float[] mix = reference.RenderAudioRange(startFrame: 0, frameCount: MixRate);
            referenceCrossings = CountZeroCrossings(mix, 0, MixRate);
        }

        // 0.5x speed: DurationFrames × Speed = 120 × 0.5 = 60 — again exactly the fixture's whole
        // 60 frames of source, this time stretched across a 120-frame (4 s) timeline span. Rendered
        // as a single continuous 3.5 s span (rather than a second, later RenderAudioRange call) so
        // the "still inside the clip" check below isn't preceded by a fresh cursor jump. The
        // RetimeStretcher now seek()-primes pre-roll after a Reset (RetimeStretcher::Seek), but this
        // clip starts at source cursor 0 (startFrame 0, trimStart 0) so there is nothing before it
        // to prime — the very first block still ramps up over ~60 ms, well within the 1 s window the
        // crossing/peak asserts average over.
        using (TimelineSession halved = OpenSine(session, speed: 0.5, durationFrames: FullSourceDurationFrames * 2))
        {
            const int totalSamples = MixRate * 7 / 2; // 3.5 s, well inside the clip's 4 s span
            float[] mix = halved.RenderAudioRange(startFrame: 0, frameCount: totalSamples);

            Peak(mix, 0, MixRate).ShouldBeGreaterThan(0.01f);
            int halvedCrossings = CountZeroCrossings(mix, 0, MixRate);

            double ratio = (double)halvedCrossings / referenceCrossings;
            ratio.ShouldBeInRange(0.85, 1.15);

            // Still audible 3.5 s in — the clip's mapped duration really is 4x the reference's
            // 1x span, not silently truncated back to the source's original 2 s.
            Peak(mix, totalSamples - 4800, 4800).ShouldBeGreaterThan(0.01f);
        }
    }
}
