namespace PalmierPro.Core.Analysis;

/// <summary>
/// Onset-strength beat detector used when Beat This ONNX is unavailable.
/// Spectral-flux style energy novelty → logits for BeatPostprocess.PickPeaks.
/// </summary>
public static class OnsetBeatDetector
{
    public static BeatAnalysis Detect(ReadOnlySpan<float> mono22050)
    {
        if (mono22050.IsEmpty)
            return new BeatAnalysis(0, [], []);

        var hop = BeatPostprocess.Hop;
        var frames = Math.Max(1, mono22050.Length / hop + 1);
        var novelty = new float[frames];
        double prev = 0;
        for (var f = 0; f < frames; f++)
        {
            var start = f * hop;
            var end = Math.Min(mono22050.Length, start + hop);
            double energy = 0;
            for (var i = start; i < end; i++)
                energy += Math.Abs(mono22050[i]);
            energy /= Math.Max(1, end - start);
            var flux = Math.Max(0, energy - prev);
            prev = energy;
            novelty[f] = (float)flux;
        }

        // Normalize to logit-ish scale centered so peaks exceed sigmoid 0.5.
        var max = novelty.Max();
        if (max <= 1e-9)
            return new BeatAnalysis(0, [], []);

        var logits = new float[frames];
        for (var i = 0; i < frames; i++)
        {
            var n = novelty[i] / max;
            // Map [0,1] → logits; strong onsets → positive.
            logits[i] = (float)(Math.Log(Math.Max(1e-6, n) / Math.Max(1e-6, 1 - n)));
        }

        var beats = BeatPostprocess.PickPeaks(logits, threshold: 0.55f);
        // Light downbeat heuristic: every 4th beat.
        var downbeats = beats.Where((_, i) => i % 4 == 0).ToList();
        var bpm = BeatPostprocess.EstimateBpm(beats) ?? 0;
        return new BeatAnalysis(bpm, beats, downbeats);
    }
}
