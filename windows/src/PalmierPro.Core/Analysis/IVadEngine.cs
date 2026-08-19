namespace PalmierPro.Core.Analysis;

public interface IVadEngine
{
    bool[] SpeechMask(ReadOnlySpan<float> mono16k);
}
