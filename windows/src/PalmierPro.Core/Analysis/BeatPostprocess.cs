namespace PalmierPro.Core.Analysis;

public sealed record BeatAnalysis(double Bpm, IReadOnlyList<double> Beats, IReadOnlyList<double> Downbeats);

/// <summary>Beat This postprocess (peak-pick + BPM) shared by ONNX and onset fallback.</summary>
public static class BeatPostprocess
{
    public const double SampleRate = 22050.0;
    public const int Hop = 441;

    public static List<double> PickPeaks(IReadOnlyList<float> logits, float threshold = 0.5f)
    {
        if (logits.Count <= 2) return [];
        var times = new List<double>();
        for (var i = 1; i < logits.Count - 1; i++)
        {
            var p = 1f / (1f + MathF.Exp(-logits[i]));
            if (p < threshold) continue;
            if (logits[i] < logits[i - 1] || logits[i] <= logits[i + 1]) continue;
            times.Add(i * Hop / SampleRate);
        }
        return times;
    }

    public static double? EstimateBpm(IReadOnlyList<double> beats)
    {
        if (beats.Count <= 2) return null;
        var intervals = new List<double>(beats.Count - 1);
        for (var i = 1; i < beats.Count; i++)
            intervals.Add(beats[i] - beats[i - 1]);
        intervals.Sort();
        var median = intervals[intervals.Count / 2];
        return median > 0 ? 60.0 / median : null;
    }
}
