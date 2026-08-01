using PalmierPro.Core.Analysis;

namespace PalmierPro.Core.Transcription;

/// <summary>
/// On-device STT. Uses <see cref="Transcriber"/> when available; otherwise VAD segment placeholders.
/// </summary>
public static class LocalStt
{
    public static ISpeechTranscriber? Transcriber { get; set; }

    public static TranscriptDocument TranscribeFile(
        string path, string mediaRef, int fps, string? language = null)
    {
        var transcriber = Transcriber;
        if (transcriber?.IsAvailable == true)
        {
            var doc = transcriber.Transcribe(path, mediaRef, fps, language);
            if (doc is not null) return doc;
        }

        return TranscribeVadFallback(path, mediaRef, fps, language);
    }

    internal static TranscriptDocument TranscribeVadFallback(
        string path, string mediaRef, int fps, string? language)
    {
        var mono = AudioPcmDecoder.DecodeMono(path, EnergyVad.SampleRate);
        var speech = VadService.Engine.SpeechMask(mono);
        var words = new List<TranscriptWord>();
        var segments = new List<TranscriptSegment>();
        var i = 0;
        var index = 0;
        var textParts = new List<string>();
        while (i < speech.Length)
        {
            if (!speech[i]) { i++; continue; }
            var j = i + 1;
            while (j < speech.Length && speech[j]) j++;
            var startSec = i * EnergyVad.CellDuration;
            var endSec = j * EnergyVad.CellDuration;
            var startFrame = (int)Math.Round(startSec * fps);
            var endFrame = Math.Max(startFrame + 1, (int)Math.Round(endSec * fps));
            var label = $"[speech {startSec:0.0}s]";
            textParts.Add(label);
            segments.Add(new TranscriptSegment
            {
                Text = label,
                StartFrame = startFrame,
                EndFrame = endFrame,
                StartSeconds = startSec,
                EndSeconds = endSec,
            });
            words.Add(new TranscriptWord
            {
                Text = label,
                StartFrame = startFrame,
                EndFrame = endFrame,
                StartSeconds = startSec,
                EndSeconds = endSec,
                Index = index++,
            });
            i = j;
        }

        return new TranscriptDocument
        {
            MediaRef = mediaRef,
            Source = "local",
            Language = language,
            Text = string.Join(" ", textParts),
            Words = words,
            Segments = segments,
        };
    }
}
