namespace PalmierPro.Core.Models;

public enum GenerationPhase
{
    None,
    Generating,
    Failed,
}

/// <summary>Runtime generation status; the manifest stores it as a machine-facing string.</summary>
public readonly record struct GenerationState(GenerationPhase Phase, string? Message = null)
{
    public static readonly GenerationState None = new(GenerationPhase.None);
    public static readonly GenerationState Generating = new(GenerationPhase.Generating);
    public static GenerationState Failed(string message) => new(GenerationPhase.Failed, message);

    public static GenerationState FromManifestValue(string? value) => value switch
    {
        null or "none" => None,
        "generating" => Generating,
        var failed when failed.StartsWith("failed:", StringComparison.Ordinal)
            => Failed(failed["failed:".Length..]),
        _ => None,
    };

    public string? ToManifestValue() => Phase switch
    {
        GenerationPhase.None => null,
        GenerationPhase.Generating => "generating",
        GenerationPhase.Failed => "failed:" + (Message ?? ""),
        _ => null,
    };
}

/// <summary>
/// Runtime media library item: a manifest entry hydrated with a resolved URL and
/// session-only state (offline flag, generation phase). Identity: Id == manifest
/// entry id == clip mediaRef.
/// </summary>
public sealed class MediaAsset
{
    public required string Id { get; init; }
    public required string Name { get; set; }
    public required ClipType Type { get; set; }
    /// <summary>Resolved absolute file path; null while offline or still generating.</summary>
    public string? Url { get; set; }
    public double Duration { get; set; }
    public int? SourceWidth { get; set; }
    public int? SourceHeight { get; set; }
    public double? SourceFPS { get; set; }
    public bool? HasAudio { get; set; }
    public string? FolderId { get; set; }
    public GenerationInput? GenerationInput { get; set; }
    public string? CachedRemoteURL { get; set; }
    public DateTime? CachedRemoteURLExpiresAt { get; set; }
    public GenerationState GenerationStatus { get; set; } = GenerationState.None;
    public MediaImportInput? ImportInput { get; set; }

    public bool IsGenerated => GenerationInput is not null;
    public bool IsGenerating => GenerationStatus.Phase == GenerationPhase.Generating;
    public bool IsMediaOffline => Url is null || !File.Exists(Url);

    public static MediaAsset FromEntry(MediaManifestEntry entry, string? resolvedUrl) => new()
    {
        Id = entry.Id,
        Name = entry.Name,
        Type = entry.Type,
        Url = resolvedUrl,
        Duration = entry.Duration,
        SourceWidth = entry.SourceWidth,
        SourceHeight = entry.SourceHeight,
        SourceFPS = entry.SourceFPS,
        HasAudio = entry.HasAudio,
        FolderId = entry.FolderId,
        GenerationInput = entry.GenerationInput,
        CachedRemoteURL = entry.CachedRemoteURL,
        CachedRemoteURLExpiresAt = entry.CachedRemoteURLExpiresAt,
        GenerationStatus = GenerationState.FromManifestValue(entry.GenerationStatus),
        ImportInput = entry.ImportInput,
    };

    /// <summary>
    /// Serializes back to a manifest entry, classifying the source as project-relative
    /// when the URL lives inside the package, external otherwise.
    /// </summary>
    public MediaManifestEntry ToManifestEntry(string? projectPath)
    {
        MediaSource source;
        if (Url is null)
        {
            source = new MediaSource.External("");
        }
        else if (projectPath is not null && PathIsInside(Url, projectPath))
        {
            var relative = Path.GetRelativePath(projectPath, Url).Replace('\\', '/');
            source = new MediaSource.Project(relative);
        }
        else
        {
            source = new MediaSource.External(Url);
        }

        return new MediaManifestEntry
        {
            Id = Id,
            Name = Name,
            Type = Type,
            Source = source,
            Duration = Duration,
            GenerationInput = GenerationInput,
            SourceWidth = SourceWidth,
            SourceHeight = SourceHeight,
            SourceFPS = SourceFPS,
            HasAudio = HasAudio,
            FolderId = FolderId,
            CachedRemoteURL = CachedRemoteURL,
            CachedRemoteURLExpiresAt = CachedRemoteURLExpiresAt,
            GenerationStatus = GenerationStatus.ToManifestValue(),
            ImportInput = ImportInput,
        };
    }

    private static bool PathIsInside(string path, string basePath)
    {
        var relative = Path.GetRelativePath(basePath, path);
        return relative != "." && !relative.StartsWith("..", StringComparison.Ordinal)
            && !Path.IsPathRooted(relative);
    }
}
