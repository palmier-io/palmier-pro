using PalmierPro.Core.Json;

namespace PalmierPro.Core.Models;

public enum GenerationStatusKind
{
    None,
    Preparing,
    Generating,
    Downloading,
    Rendering,
    Failed,
}

/// Ports `MediaAsset.GenerationStatus`, a Swift enum with an associated value on `.failed`. Not
/// itself Codable — MediaAsset persists it as a plain string on <see cref="MediaManifestEntry.GenerationStatus"/>
/// via <see cref="Serialized"/>/<see cref="FromSerialized"/>.
public sealed class GenerationStatus : IEquatable<GenerationStatus>
{
    private const string FailurePrefix = "failed: ";

    public GenerationStatusKind Kind { get; }
    public string? FailureMessage { get; }

    private GenerationStatus(GenerationStatusKind kind, string? failureMessage = null)
    {
        Kind = kind;
        FailureMessage = failureMessage;
    }

    public static readonly GenerationStatus None = new(GenerationStatusKind.None);
    public static readonly GenerationStatus Preparing = new(GenerationStatusKind.Preparing);
    public static readonly GenerationStatus Generating = new(GenerationStatusKind.Generating);
    public static readonly GenerationStatus Downloading = new(GenerationStatusKind.Downloading);
    public static readonly GenerationStatus Rendering = new(GenerationStatusKind.Rendering);

    public static GenerationStatus Failed(string message) => new(GenerationStatusKind.Failed, message);

    public string Serialized => Kind switch
    {
        GenerationStatusKind.None => "none",
        GenerationStatusKind.Preparing => "preparing",
        GenerationStatusKind.Generating => "generating",
        GenerationStatusKind.Downloading => "downloading",
        GenerationStatusKind.Rendering => "rendering",
        GenerationStatusKind.Failed => FailurePrefix + FailureMessage,
        _ => throw new ArgumentOutOfRangeException(),
    };

    /// `.none`/`.preparing` are transient and must not restore as in-progress.
    public string? ManifestValue => Kind is GenerationStatusKind.None or GenerationStatusKind.Preparing ? null : Serialized;

    public static GenerationStatus FromSerialized(string? value)
    {
        if (value is null)
        {
            return None;
        }
        return value switch
        {
            "preparing" => Preparing,
            "generating" => Generating,
            "downloading" => Downloading,
            "rendering" => Rendering,
            _ when value.StartsWith(FailurePrefix, StringComparison.Ordinal) => Failed(value[FailurePrefix.Length..]),
            _ => None,
        };
    }

    public bool Equals(GenerationStatus? other) => other is not null && Kind == other.Kind && FailureMessage == other.FailureMessage;
    public override bool Equals(object? obj) => Equals(obj as GenerationStatus);
    public override int GetHashCode() => HashCode.Combine(Kind, FailureMessage);
    public static bool operator ==(GenerationStatus? a, GenerationStatus? b) => Equals(a, b);
    public static bool operator !=(GenerationStatus? a, GenerationStatus? b) => !Equals(a, b);
}

/// Runtime media-library entry. Unlike the Mac's `@Observable @MainActor` class (backed live by
/// NSImage/AVFoundation), this is a plain data+logic class — thumbnail generation and format
/// probing are seamed out via <see cref="IMediaProbe"/> for a platform layer to implement; `Id`
/// and `Type` are get-only, mirroring the Mac's `let id`/`let type` (never reassigned).
public sealed class MediaAsset
{
    public string Id { get; }
    public string Url { get; set; }
    public ClipType Type { get; }
    public string Name { get; set; }
    public double Duration { get; set; }
    public int? SourceWidth { get; set; }
    public int? SourceHeight { get; set; }
    public double? SourceFPS { get; set; }
    public bool HasAudio { get; set; }
    public GenerationInput? GenerationInput { get; set; }
    public MediaImportInput? ImportInput { get; set; }
    public GenerationStatus GenerationStatus { get; set; } = GenerationStatus.None;
    public string? FolderId { get; set; }
    public string? PendingDownloadUrl { get; set; }
    public string? CachedRemoteUrl { get; set; }
    public DateTimeOffset? CachedRemoteUrlExpiresAt { get; set; }

    public MediaAsset(string url, ClipType type, string name, string? id = null, double duration = 0, GenerationInput? generationInput = null)
    {
        Id = id ?? SwiftId.New();
        Url = url;
        Type = type;
        Name = name;
        Duration = duration;
        GenerationInput = generationInput;
        HasAudio = type == ClipType.Video;
    }

    /// Reconstruct from a manifest entry + resolved path.
    public static MediaAsset FromManifestEntry(MediaManifestEntry entry, string resolvedUrl)
    {
        var asset = new MediaAsset(resolvedUrl, entry.Type, entry.Name, entry.Id, entry.Duration, entry.GenerationInput)
        {
            SourceWidth = entry.SourceWidth,
            SourceHeight = entry.SourceHeight,
            SourceFPS = entry.SourceFPS,
            HasAudio = entry.HasAudio ?? false,
            FolderId = entry.FolderId,
            CachedRemoteUrl = entry.CachedRemoteURL,
            CachedRemoteUrlExpiresAt = entry.CachedRemoteURLExpiresAt,
            ImportInput = entry.ImportInput,
        };
        var restoredStatus = GenerationStatus.FromSerialized(entry.GenerationStatus);
        asset.GenerationStatus = restoredStatus.Kind == GenerationStatusKind.Preparing && !asset.CanResumeGeneration
            ? GenerationStatus.None
            : restoredStatus;
        return asset;
    }

    /// The cached remote URL if set AND not expired; else null.
    public string? FreshRemoteUrl =>
        CachedRemoteUrl is { } url && CachedRemoteUrlExpiresAt is { } expiresAt && expiresAt > DateTimeOffset.UtcNow
            ? url
            : null;

    public bool IsGenerated => GenerationInput is not null;

    public bool CanResumeGeneration => GenerationInput?.BackendJobId is { Length: > 0 };

    public bool IsGenerating =>
        GenerationStatus == GenerationStatus.Preparing || GenerationStatus == GenerationStatus.Generating ||
        GenerationStatus == GenerationStatus.Downloading || GenerationStatus == GenerationStatus.Rendering;

    public bool IsRecoveringGeneration
    {
        get
        {
            if (!CanResumeGeneration)
            {
                return false;
            }
            if (IsGenerating)
            {
                return true;
            }
            if (GenerationStatus.Kind == GenerationStatusKind.Failed)
            {
                return GenerationInput?.ResultUrls is { Count: > 0 };
            }
            return false;
        }
    }

    public string GeneratingLabel => GenerationStatus.Kind switch
    {
        GenerationStatusKind.Preparing => "Preparing...",
        GenerationStatusKind.Downloading => "Downloading...",
        GenerationStatusKind.Rendering => "Rendering...",
        _ => "Generating...",
    };

    /// Produce a serializable manifest entry. When `Url` lives under `projectPath`, the source is
    /// stored project-relative instead of absolute (mirrors `url.path.hasPrefix(projectURL.path)`).
    public MediaManifestEntry ToManifestEntry(string? projectPath)
    {
        MediaSource source;
        if (projectPath is not null && Url.StartsWith(projectPath, StringComparison.Ordinal))
        {
            // Mirrors Swift's `dropFirst(count + 1)`, which clamps to "" instead of throwing when
            // Url equals projectPath exactly (StartsWith is true but there's nothing past it).
            var relative = Url.Length > projectPath.Length ? Url[(projectPath.Length + 1)..] : "";
            source = MediaSource.Project(relative);
        }
        else
        {
            source = MediaSource.External(Url);
        }
        var fresh = FreshRemoteUrl;
        return new MediaManifestEntry(
            id: Id, name: Name, type: Type, source: source, duration: Duration,
            generationInput: GenerationInput,
            sourceWidth: SourceWidth, sourceHeight: SourceHeight, sourceFPS: SourceFPS,
            hasAudio: HasAudio, folderId: FolderId,
            cachedRemoteURL: fresh,
            cachedRemoteURLExpiresAt: fresh is null ? null : CachedRemoteUrlExpiresAt,
            generationStatus: GenerationStatus.ManifestValue,
            importInput: ImportInput);
    }

    /// Ports `loadMetadata()`'s branching by clip type; the actual format probing is `probe`'s job.
    public async Task<bool> LoadMetadataAsync(IMediaProbe probe)
    {
        if (Type == ClipType.Image)
        {
            Duration = Defaults.ImageDurationSeconds;
            var meta = await probe.ProbeImageAsync(Url).ConfigureAwait(false);
            if (meta?.Width is { } w)
            {
                SourceWidth = w;
            }
            if (meta?.Height is { } h)
            {
                SourceHeight = h;
            }
            return meta?.Width is not null && meta?.Height is not null;
        }

        if (Type == ClipType.Lottie)
        {
            var info = await probe.ProbeLottieAsync(Url).ConfigureAwait(false);
            if (info is null)
            {
                return false;
            }
            Duration = info.Duration;
            SourceWidth = (int)info.Width;
            SourceHeight = (int)info.Height;
            SourceFPS = info.FrameRate;
            return true;
        }

        if (Type != ClipType.Video && Type != ClipType.Audio)
        {
            return true;
        }

        if (Type == ClipType.Audio)
        {
            var assetDuration = await probe.ProbeAssetDurationAsync(Url).ConfigureAwait(false);
            if (assetDuration is { } d)
            {
                Duration = d;
            }
            return await probe.HasAudioTrackAsync(Url).ConfigureAwait(false) == true;
        }

        // Type == ClipType.Video
        var video = await probe.ProbeVideoAsync(Url).ConfigureAwait(false);
        if (video is not null)
        {
            if (video.Width is { } vw)
            {
                SourceWidth = vw;
            }
            if (video.Height is { } vh)
            {
                SourceHeight = vh;
            }
            if (video.FrameRate is { } fr && fr > 0)
            {
                SourceFPS = fr;
            }
        }
        if (video?.VideoTrackDurationSeconds is { } videoDuration)
        {
            Duration = videoDuration;
        }
        else
        {
            var assetDuration = await probe.ProbeAssetDurationAsync(Url).ConfigureAwait(false);
            if (assetDuration is { } d)
            {
                Duration = d;
            }
        }
        var hasAudioTrack = await probe.HasAudioTrackAsync(Url).ConfigureAwait(false);
        if (hasAudioTrack is { } ha)
        {
            HasAudio = ha;
        }
        return video?.HasVideoTrack ?? false;
    }
}
