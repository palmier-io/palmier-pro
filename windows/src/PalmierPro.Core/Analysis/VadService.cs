namespace PalmierPro.Core.Analysis;

public static class VadService
{
    public static IVadEngine Engine { get; set; } = EnergyVadEngine.Instance;

    public static bool[] QuietNonSpeechMask(ReadOnlySpan<float> mono16k, double cellDuration = EnergyVad.CellDuration)
    {
        var speech = Engine.SpeechMask(mono16k);
        var quiet = new bool[speech.Length];
        for (var i = 0; i < speech.Length; i++)
            quiet[i] = !speech[i];
        return quiet;
    }
}

public sealed class EnergyVadEngine : IVadEngine
{
    public static EnergyVadEngine Instance { get; } = new();

    public bool[] SpeechMask(ReadOnlySpan<float> mono16k)
        => EnergyVad.SpeechMask(mono16k);
}
