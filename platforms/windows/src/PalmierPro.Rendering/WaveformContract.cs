namespace PalmierPro.Rendering;

// Mirrors Sources/PalmierPro/Audio/WaveformExtractor.swift's contract. PE_ExtractPeakEnvelope
// does raw mono max-magnitude reduction only; the dB normalization (0 = loud, 1 = silent)
// happens here, matching the Swift implementation's `normalized(peak:)` exactly.
public static class WaveformContract
{
    public const double SamplesPerSecond = 200;
    public const float NoiseFloorDb = -50f;
    public const int MaxSamples = 240_000;

    public static float Normalize(float peak)
    {
        if (peak <= 0)
        {
            return 1f;
        }
        double db = 20 * Math.Log10(peak);
        double clamped = Math.Min(0, Math.Max(NoiseFloorDb, db));
        return (float)(clamped / NoiseFloorDb);
    }
}
