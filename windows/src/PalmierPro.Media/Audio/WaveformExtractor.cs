using NAudio.Wave;

namespace PalmierPro.Media.Audio;

/// <summary>
/// Extracts a normalized peak envelope from a media file's audio, matching the Mac
/// WaveformExtractor: ~200 samples/sec capped at 240k samples, values normalized against
/// a -50 dB noise floor where 0 = loud and 1 = silence.
/// </summary>
public static class WaveformExtractor
{
    public const double SamplesPerSecond = 200;
    public const float NoiseFloorDb = -50;
    public const int MaxSamples = 240_000;

    public static Task<float[]> PeakEnvelopeAsync(
        string path,
        (double Start, double End)? range = null,
        CancellationToken cancellationToken = default)
        => Task.Run(() => PeakEnvelope(path, range, cancellationToken), cancellationToken);

    private static float[] PeakEnvelope(string path, (double Start, double End)? range, CancellationToken ct)
    {
        using var reader = new MediaFoundationReader(path);
        var samples = reader.ToSampleProvider();
        var format = samples.WaveFormat;
        int channels = format.Channels;
        double sampleRate = format.SampleRate;

        double totalSeconds = reader.TotalTime.TotalSeconds;
        double startSeconds = 0;
        double span = totalSeconds;
        if (range is { } r)
        {
            startSeconds = Math.Max(0, r.Start);
            span = Math.Max(0, Math.Min(totalSeconds, r.End) - startSeconds);
            reader.CurrentTime = TimeSpan.FromSeconds(startSeconds);
        }

        double rate = double.IsFinite(span) && span > 0
            ? Math.Min(SamplesPerSecond, MaxSamples / span)
            : SamplesPerSecond;
        int hopFrames = Math.Max(1, (int)Math.Round(sampleRate / rate));

        var envelope = new List<float>(Math.Min(MaxSamples, 4096));
        var buffer = new float[hopFrames * channels];
        long framesRemaining = double.IsFinite(span) && span > 0
            ? (long)(span * sampleRate)
            : long.MaxValue;

        while (framesRemaining > 0)
        {
            ct.ThrowIfCancellationRequested();
            int wanted = (int)Math.Min(hopFrames, framesRemaining) * channels;
            int read = ReadFully(samples, buffer, wanted);
            if (read == 0) break;

            float peak = 0;
            for (var i = 0; i < read; i++)
            {
                var magnitude = Math.Abs(buffer[i]);
                if (magnitude > peak) peak = magnitude;
            }
            envelope.Add(Normalized(peak));
            framesRemaining -= read / channels;
            if (envelope.Count >= MaxSamples) break;
        }
        return [.. envelope];
    }

    private static int ReadFully(ISampleProvider provider, float[] buffer, int count)
    {
        var total = 0;
        while (total < count)
        {
            var read = provider.Read(buffer, total, count - total);
            if (read == 0) break;
            total += read;
        }
        return total;
    }

    /// <summary>0 = loud, 1 = silence; silent hops map to 1 so timeline bars draw nothing.</summary>
    internal static float Normalized(float peak)
    {
        if (peak <= 0) return 1;
        var db = 20f * MathF.Log10(peak);
        var clamped = MathF.Min(0, MathF.Max(NoiseFloorDb, db));
        return clamped / NoiseFloorDb;
    }
}
