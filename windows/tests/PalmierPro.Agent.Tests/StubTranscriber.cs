using PalmierPro.Core.Transcription;

namespace PalmierPro.Agent.Tests;

internal sealed class StubTranscriber : ISpeechTranscriber
{
    public bool IsAvailable => true;

    public TranscriptDocument? Transcribe(string path, string mediaRef, int fps, string? language)
        => new TranscriptDocument
        {
            MediaRef = mediaRef,
            Source = "whisper",
            Text = "stub",
            Words = [new TranscriptWord { Text = "stub", StartFrame = 0, EndFrame = 10, Index = 0 }],
            Segments = [new TranscriptSegment { Text = "stub", StartFrame = 0, EndFrame = 10 }],
        };
}
