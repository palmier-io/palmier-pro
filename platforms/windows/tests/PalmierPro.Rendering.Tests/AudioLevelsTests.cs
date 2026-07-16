using PalmierPro.Core.Models;
using PalmierPro.Services.Engine;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// Master meter tap (Stage E, AudioMeterView): PE_TimelineGetAudioLevels reads the same lock-free
// snapshot PE_TimelineRenderAudioRange writes (TimelineSession::UpdateAudioLevels), so this drives
// it through the deterministic offline mix hook — no XAudio2 device, same pinned 1 kHz sine
// fixture as TimelineAudioMixerTests. Values are raw linear amplitude (the C# AudioMeterHub port
// owns the dB mapping/ballistics — see PalmierPro.Core.Audio).
[Collection(MediaFixturesCollection.Name)]
public sealed class AudioLevelsTests(MediaFixtures fixtures)
{
    private const int Fps = 30;
    private const int MixRate = 48000;
    private const int ClipDurationFrames = 60; // the 2 s fixture, whole

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

    private static (float Peak, float Rms) ReferencePeakRms(float[] interleaved, int channel)
    {
        float peak = 0f;
        double sumSq = 0.0;
        int count = interleaved.Length / 2;
        for (int i = 0; i < count; i++)
        {
            float sample = interleaved[i * 2 + channel];
            peak = Math.Max(peak, Math.Abs(sample));
            sumSq += (double)sample * sample;
        }
        return (peak, count > 0 ? (float)Math.Sqrt(sumSq / count) : 0f);
    }

    [Fact]
    [Trait("Category", "Media")]
    public void GetAudioLevels_IsSilentBeforeAnyBlockIsMixed()
    {
        using var session = new EngineSession();
        using TimelineSession timeline = OpenSine(session);

        var (leftPeak, leftRms, rightPeak, rightRms) = timeline.GetAudioLevels();

        leftPeak.ShouldBe(0f);
        leftRms.ShouldBe(0f);
        rightPeak.ShouldBe(0f);
        rightRms.ShouldBe(0f);
    }

    [Fact]
    [Trait("Category", "Media")]
    public void GetAudioLevels_AfterRenderAudioRange_MatchesTheMixedBlockForAKnownSine()
    {
        using var session = new EngineSession();
        using TimelineSession timeline = OpenSine(session);

        float[] mix = timeline.RenderAudioRange(startFrame: 0, frameCount: MixRate);
        var (leftPeak, leftRms, rightPeak, rightRms) = timeline.GetAudioLevels();

        var (expectedLeftPeak, expectedLeftRms) = ReferencePeakRms(mix, channel: 0);
        var (expectedRightPeak, expectedRightRms) = ReferencePeakRms(mix, channel: 1);

        // The tap read exactly the block RenderAudioRange just mixed (guards against an all-silent
        // false pass, and against the tap reading some other/stale buffer).
        leftPeak.ShouldBeGreaterThan(0f);
        leftPeak.ShouldBe(expectedLeftPeak, tolerance: 1e-6);
        leftRms.ShouldBe(expectedLeftRms, tolerance: 1e-6);
        rightPeak.ShouldBe(expectedRightPeak, tolerance: 1e-6);
        rightRms.ShouldBe(expectedRightRms, tolerance: 1e-6);

        // A sine's RMS/peak ratio is 1/sqrt(2) ≈ 0.7071 regardless of amplitude — "expected levels
        // for a known sine," independent of the fixture's exact absolute amplitude.
        (leftRms / leftPeak).ShouldBe(0.7071f, tolerance: 0.02);
        (rightRms / rightPeak).ShouldBe(0.7071f, tolerance: 0.02);
    }
}
