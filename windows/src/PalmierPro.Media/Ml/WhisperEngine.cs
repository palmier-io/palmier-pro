using PalmierPro.Core.Analysis;
using PalmierPro.Core.Transcription;
using Whisper.net;

namespace PalmierPro.Media.Ml;

public sealed class WhisperEngine : ISpeechTranscriber, IDisposable
{
    private readonly string? _modelPath;
    private WhisperFactory? _factory;
    private readonly object _gate = new();

    public WhisperEngine()
    {
        _modelPath = LocalModelPaths.ResolveWhisperModel();
    }

    public bool IsAvailable => _modelPath is not null;

    public TranscriptDocument? Transcribe(string path, string mediaRef, int fps, string? language)
    {
        if (!IsAvailable) return null;

        float[] mono;
        try { mono = AudioPcmDecoder.DecodeMono(path, EnergyVad.SampleRate); }
        catch { return null; }

        var factory = GetFactory();
        if (factory is null) return null;

        var builder = factory.CreateBuilder().SplitOnWord();
        if (!string.IsNullOrWhiteSpace(language))
            builder = builder.WithLanguage(language);
        else
            builder = builder.WithLanguage("auto");

        var results = new List<SegmentData>();
        using var processor = builder.WithSegmentEventHandler(results.Add).Build();
        try { processor.Process(mono); }
        catch { return null; }

        return BuildDocument(results, mediaRef, fps, language);
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _factory?.Dispose();
            _factory = null;
        }
    }

    private WhisperFactory? GetFactory()
    {
        if (_modelPath is null) return null;
        lock (_gate)
        {
            _factory ??= WhisperFactory.FromPath(_modelPath);
            return _factory;
        }
    }

    private static TranscriptDocument? BuildDocument(
        List<SegmentData> results, string mediaRef, int fps, string? language)
    {
        var words = new List<TranscriptWord>();
        var segments = new List<TranscriptSegment>();
        var textParts = new List<string>();
        var index = 0;
        TranscriptSegment? openSegment = null;

        foreach (var result in results)
        {
            var text = result.Text.Trim();
            if (string.IsNullOrEmpty(text)) continue;

            var startSec = result.Start.TotalSeconds;
            var endSec = result.End.TotalSeconds;
            if (endSec <= startSec) endSec = startSec + 0.05;
            var startFrame = (int)Math.Round(startSec * fps);
            var endFrame = Math.Max(startFrame + 1, (int)Math.Round(endSec * fps));

            words.Add(new TranscriptWord
            {
                Text = text,
                StartFrame = startFrame,
                EndFrame = endFrame,
                StartSeconds = startSec,
                EndSeconds = endSec,
                Index = index++,
            });
            textParts.Add(text);

            if (openSegment is null || startSec - (openSegment.EndSeconds ?? SegmentEndSeconds(openSegment, fps)) > 0.75)
            {
                if (openSegment is not null) segments.Add(openSegment);
                openSegment = new TranscriptSegment
                {
                    Text = text,
                    StartFrame = startFrame,
                    EndFrame = endFrame,
                    StartSeconds = startSec,
                    EndSeconds = endSec,
                };
            }
            else
            {
                openSegment = new TranscriptSegment
                {
                    Text = openSegment.Text + " " + text,
                    StartFrame = openSegment.StartFrame,
                    EndFrame = endFrame,
                    StartSeconds = openSegment.StartSeconds,
                    EndSeconds = endSec,
                    Speaker = openSegment.Speaker,
                };
            }
        }

        if (openSegment is not null) segments.Add(openSegment);
        if (words.Count == 0) return null;

        return new TranscriptDocument
        {
            MediaRef = mediaRef,
            Source = "whisper",
            Language = language,
            Text = string.Join(" ", textParts),
            Words = words,
            Segments = segments,
        };
    }

    private static double SegmentEndSeconds(TranscriptSegment segment, int fps)
        => segment.EndFrame / (double)Math.Max(1, fps);
}
