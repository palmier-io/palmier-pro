using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

[Collection(MediaFixturesCollection.Name)]
public sealed class PeakEnvelopeTests(MediaFixtures fixtures)
{
    [Fact]
    [Trait("Category", "Media")]
    public void ExtractPeakEnvelope_LengthMatchesDurationTimesRate()
    {
        using var session = new EngineSession();
        using MediaSource media = session.OpenMedia(fixtures.AudioOnlyPath);

        double durationSeconds = media.Info.Duration.TotalSeconds;
        float[] peaks = media.ExtractPeakEnvelope(0, durationSeconds);

        double rate = Math.Min(WaveformContract.SamplesPerSecond, WaveformContract.MaxSamples / durationSeconds);
        int expectedCount = (int)Math.Round(durationSeconds * rate);

        peaks.Length.ShouldBeInRange(expectedCount - 2, expectedCount + 2);
    }

    [Fact]
    [Trait("Category", "Media")]
    public void ExtractPeakEnvelope_SineWaveYieldsNearConstantPeaks()
    {
        using var session = new EngineSession();
        using MediaSource media = session.OpenMedia(fixtures.AudioOnlyPath);

        float[] peaks = media.ExtractPeakEnvelope(0, media.Info.Duration.TotalSeconds);

        peaks.Length.ShouldBeGreaterThan(10);

        // Drop the first/last window (partial-hop edge effects) — a steady full-scale
        // sine wave should normalize to nearly the same loudness value throughout.
        float[] steady = [.. peaks.Skip(2).SkipLast(2)];
        float min = steady.Min();
        float max = steady.Max();
        (max - min).ShouldBeLessThan(0.05f);
    }

    [Fact]
    [Trait("Category", "Media")]
    public void ExtractPeakEnvelope_CompressedAudio_MatchesDurationTimesRate()
    {
        using var session = new EngineSession();
        using MediaSource media = session.OpenMedia(fixtures.VideoWithAudioPath);

        double durationSeconds = media.Info.Duration.TotalSeconds;
        float[] peaks = media.ExtractPeakEnvelope(0, durationSeconds);

        double rate = Math.Min(WaveformContract.SamplesPerSecond, WaveformContract.MaxSamples / durationSeconds);
        int expectedCount = (int)Math.Round(durationSeconds * rate);

        // Same +/-2 tolerance as the PCM-fixture length test above, but on VideoWithAudioPath's
        // AAC audio — no test previously exercised ExtractPeakEnvelope's full-duration length on
        // compressed audio at all (only the zero-duration error path below touched this fixture).
        peaks.Length.ShouldBeInRange(expectedCount - 2, expectedCount + 2);
    }

    [Fact]
    [Trait("Category", "Media")]
    public void ExtractPeakEnvelope_RequestBeyondStreamEnd_DrainsToPhysicalEofWithoutHanging()
    {
        using var session = new EngineSession();
        using MediaSource media = session.OpenMedia(fixtures.VideoWithAudioPath);

        double durationSeconds = media.Info.Duration.TotalSeconds;

        // Requesting past the reported duration means the read loop can only terminate via real
        // physical EOF (av_read_frame < 0), never the windowEnd cutoff — this is what exercises
        // the decoder-drain + swr-flush path added for parity with SeekAndDecodeVideo's own EOF
        // flush (a codec/build whose decoder does buffer trailing frames depends on it).
        float[] peaks = media.ExtractPeakEnvelope(0, durationSeconds + 1.0);

        peaks.Length.ShouldBeGreaterThan(0);
    }

    [Fact]
    [Trait("Category", "Media")]
    public void ExtractPeakEnvelope_ZeroDuration_ThrowsArgumentOutOfRange()
    {
        using var session = new EngineSession();
        using MediaSource media = session.OpenMedia(fixtures.VideoWithAudioPath);

        Should.Throw<ArgumentOutOfRangeException>(() => media.ExtractPeakEnvelope(0, 0));
    }
}
