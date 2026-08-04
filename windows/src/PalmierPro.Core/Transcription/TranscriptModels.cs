namespace PalmierPro.Core.Transcription;

public sealed class TranscriptWord
{
    public required string Text { get; init; }
    public required int StartFrame { get; init; }
    public required int EndFrame { get; init; }
    public double? StartSeconds { get; init; }
    public double? EndSeconds { get; init; }
    public int Index { get; init; }
    public string? Speaker { get; init; }
    /// <summary>Owning timeline clip when built via timeline walk.</summary>
    public string? ClipId { get; init; }
    public int? TrackIndex { get; init; }
}

public sealed class TranscriptSegment
{
    public required string Text { get; init; }
    public required int StartFrame { get; init; }
    public required int EndFrame { get; init; }
    public double? StartSeconds { get; init; }
    public double? EndSeconds { get; init; }
    public string? Speaker { get; init; }
}

public sealed class TranscriptDocument
{
    public required string MediaRef { get; init; }
    public required string Source { get; init; } // "local" | "whisper" | "cloud"
    public string? Language { get; init; }
    public required string Text { get; init; }
    public List<TranscriptWord> Words { get; init; } = [];
    public List<TranscriptSegment> Segments { get; init; } = [];
}

/// <summary>Last get_transcript result per project — remove_words reuses indices.</summary>
public sealed class TranscriptCache
{
    public static TranscriptCache Shared { get; } = new();

    private readonly Dictionary<string, TranscriptDocument> _byKey = new(StringComparer.Ordinal);

    public void Store(string projectKey, TranscriptDocument doc)
        => _byKey[projectKey] = doc;

    public TranscriptDocument? Get(string projectKey)
        => _byKey.TryGetValue(projectKey, out var d) ? d : null;

    public void Clear(string projectKey) => _byKey.Remove(projectKey);
}
