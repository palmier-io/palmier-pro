namespace PalmierPro.Core.Analysis;

/// <summary>
/// Energy-based VAD stand-in for Silero ONNX. Builds a speech mask from mono PCM
/// using per-cell RMS vs a relative threshold (Mac quiet-non-speech pairing).
/// </summary>
public static class EnergyVad
{
    public const int SampleRate = 16000;
    public const double CellDuration = 0.032;

    public static bool[] SpeechMask(ReadOnlySpan<float> mono, double cellDuration = CellDuration)
    {
        if (mono.IsEmpty || cellDuration <= 0) return [];
        var cellSamples = Math.Max(1, (int)Math.Round(SampleRate * cellDuration));
        var cells = (mono.Length + cellSamples - 1) / cellSamples;
        var levels = new double[cells];
        for (var c = 0; c < cells; c++)
        {
            var start = c * cellSamples;
            var end = Math.Min(mono.Length, start + cellSamples);
            double sum = 0;
            for (var i = start; i < end; i++)
                sum += mono[i] * mono[i];
            levels[c] = Math.Sqrt(sum / Math.Max(1, end - start));
        }

        var speechLevels = levels.Where(l => l > 1e-6).OrderBy(l => l).ToList();
        if (speechLevels.Count == 0) return new bool[cells];
        var median = speechLevels[speechLevels.Count / 2];
        var threshold = Math.Max(1e-5, median * 0.25); // ~12 dB below speech median
        var speech = new bool[cells];
        for (var i = 0; i < cells; i++)
            speech[i] = levels[i] >= threshold;
        return speech;
    }

    public static bool[] QuietNonSpeechMask(ReadOnlySpan<float> mono, double cellDuration = CellDuration)
    {
        var speech = SpeechMask(mono, cellDuration);
        var quiet = new bool[speech.Length];
        for (var i = 0; i < speech.Length; i++)
            quiet[i] = !speech[i];
        return quiet;
    }
}
