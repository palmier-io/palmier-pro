namespace PalmierPro.Core.Transcription;

public interface ISpeechTranscriber
{
    bool IsAvailable { get; }
    TranscriptDocument? Transcribe(string path, string mediaRef, int fps, string? language);
}
