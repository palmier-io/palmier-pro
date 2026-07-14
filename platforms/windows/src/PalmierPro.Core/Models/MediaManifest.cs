using System.Text.Json;
using System.Text.Json.Serialization;
using PalmierPro.Core.Json;

namespace PalmierPro.Core.Models;

/// Root of media.json. Custom Swift decoder: `version` falls back to 1 (the pre-versioned
/// legacy shape), NOT the type's own default of 2 (which only applies to freshly-constructed
/// manifests) — `entries`/`folders` fall back to empty.
[JsonConverter(typeof(MediaManifestJsonConverter))]
public sealed class MediaManifest
{
    public int Version { get; set; } = 2;
    public List<MediaManifestEntry> Entries { get; set; } = [];
    public List<MediaFolder> Folders { get; set; } = [];
}

public sealed class MediaManifestJsonConverter : JsonConverter<MediaManifest>
{
    private const int LegacyVersion = 1;

    public override MediaManifest Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;
        return new MediaManifest
        {
            Version = LenientJson.PresentOr(root, "version", options, LegacyVersion),
            Entries = LenientJson.PresentOr(root, "entries", options, new List<MediaManifestEntry>()),
            Folders = LenientJson.PresentOr(root, "folders", options, new List<MediaFolder>()),
        };
    }

    public override void Write(Utf8JsonWriter writer, MediaManifest value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteNumber("version", value.Version);
        writer.WritePropertyName("entries");
        JsonSerializer.Serialize(writer, value.Entries, options);
        writer.WritePropertyName("folders");
        JsonSerializer.Serialize(writer, value.Folders, options);
        writer.WriteEndObject();
    }
}

/// One media-library row. Synthesized Codable, no custom init: `id`/`name`/`type`/`source`/`duration`
/// are required, everything else is Optional-lenient (missing/null -> null, wrong type -> throws —
/// this type has no `try?` leniency anywhere, unlike Timeline/Track/Clip).
public sealed class MediaManifestEntry
{
    [JsonPropertyName("id")]
    [JsonRequired]
    public string Id { get; set; } = "";

    [JsonPropertyName("name")]
    [JsonRequired]
    public string Name { get; set; } = "";

    [JsonPropertyName("type")]
    [JsonRequired]
    public ClipType Type { get; set; }

    [JsonPropertyName("source")]
    [JsonRequired]
    public MediaSource Source { get; set; } = null!;

    [JsonPropertyName("duration")]
    [JsonRequired]
    public double Duration { get; set; }

    [JsonPropertyName("generationInput")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public GenerationInput? GenerationInput { get; set; }

    [JsonPropertyName("sourceWidth")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? SourceWidth { get; set; }

    [JsonPropertyName("sourceHeight")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? SourceHeight { get; set; }

    [JsonPropertyName("sourceFPS")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? SourceFPS { get; set; }

    [JsonPropertyName("hasAudio")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? HasAudio { get; set; }

    [JsonPropertyName("folderId")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? FolderId { get; set; }

    [JsonPropertyName("cachedRemoteURL")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? CachedRemoteURL { get; set; }

    [JsonPropertyName("cachedRemoteURLExpiresAt")]
    [JsonConverter(typeof(SwiftDateJsonConverter))]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public DateTimeOffset? CachedRemoteURLExpiresAt { get; set; }

    [JsonPropertyName("generationStatus")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? GenerationStatus { get; set; }

    [JsonPropertyName("importInput")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public MediaImportInput? ImportInput { get; set; }

    public MediaManifestEntry()
    {
    }

    public MediaManifestEntry(
        string id, string name, ClipType type, MediaSource source, double duration,
        GenerationInput? generationInput = null,
        int? sourceWidth = null, int? sourceHeight = null, double? sourceFPS = null,
        bool? hasAudio = null, string? folderId = null,
        string? cachedRemoteURL = null, DateTimeOffset? cachedRemoteURLExpiresAt = null,
        string? generationStatus = null, MediaImportInput? importInput = null)
    {
        Id = id;
        Name = name;
        Type = type;
        Source = source;
        Duration = duration;
        GenerationInput = generationInput;
        SourceWidth = sourceWidth;
        SourceHeight = sourceHeight;
        SourceFPS = sourceFPS;
        HasAudio = hasAudio;
        FolderId = folderId;
        CachedRemoteURL = cachedRemoteURL;
        CachedRemoteURLExpiresAt = cachedRemoteURLExpiresAt;
        GenerationStatus = generationStatus;
        ImportInput = importInput;
    }
}

/// All-Optional; no custom Swift init, so every field is missing/null -> null, wrong type -> throws.
public sealed class MediaImportInput
{
    [JsonPropertyName("sourceURL")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SourceUrl { get; set; }

    [JsonPropertyName("sourcePath")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SourcePath { get; set; }

    [JsonPropertyName("createdAt")]
    [JsonConverter(typeof(SwiftDateJsonConverter))]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public DateTimeOffset? CreatedAt { get; set; }
}

/// Everything past `aspectRatio` is Optional-lenient (no custom Swift init); the first four
/// fields have no default in Swift, so they're required on decode.
public sealed class GenerationInput
{
    [JsonPropertyName("prompt")]
    [JsonRequired]
    public string Prompt { get; set; } = "";

    [JsonPropertyName("model")]
    [JsonRequired]
    public string Model { get; set; } = "";

    [JsonPropertyName("duration")]
    [JsonRequired]
    public int Duration { get; set; }

    [JsonPropertyName("aspectRatio")]
    [JsonRequired]
    public string AspectRatio { get; set; } = "";

    [JsonPropertyName("resolution")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Resolution { get; set; }

    [JsonPropertyName("quality")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Quality { get; set; }

    [JsonPropertyName("imageURLs")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<string>? ImageUrls { get; set; }

    /// Image-only.
    [JsonPropertyName("numImages")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? NumImages { get; set; }

    /// Audio-only.
    [JsonPropertyName("voice")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Voice { get; set; }

    [JsonPropertyName("lyrics")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Lyrics { get; set; }

    [JsonPropertyName("styleInstructions")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? StyleInstructions { get; set; }

    [JsonPropertyName("instrumental")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? Instrumental { get; set; }

    [JsonPropertyName("targetLanguage")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? TargetLanguage { get; set; }

    /// Video-only.
    [JsonPropertyName("generateAudio")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? GenerateAudio { get; set; }

    [JsonPropertyName("referenceImageURLs")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<string>? ReferenceImageUrls { get; set; }

    [JsonPropertyName("referenceVideoURLs")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<string>? ReferenceVideoUrls { get; set; }

    [JsonPropertyName("referenceAudioURLs")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<string>? ReferenceAudioUrls { get; set; }

    /// Asset IDs for the references.
    [JsonPropertyName("imageURLAssetIds")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<string>? ImageUrlAssetIds { get; set; }

    [JsonPropertyName("referenceImageAssetIds")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<string>? ReferenceImageAssetIds { get; set; }

    [JsonPropertyName("referenceVideoAssetIds")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<string>? ReferenceVideoAssetIds { get; set; }

    [JsonPropertyName("referenceAudioAssetIds")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<string>? ReferenceAudioAssetIds { get; set; }

    [JsonPropertyName("createdAt")]
    [JsonConverter(typeof(SwiftDateJsonConverter))]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public DateTimeOffset? CreatedAt { get; set; }

    [JsonPropertyName("backendJobId")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? BackendJobId { get; set; }

    [JsonPropertyName("outputIndex")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? OutputIndex { get; set; }

    [JsonPropertyName("resultURLs")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<string>? ResultUrls { get; set; }
}

public enum MediaSourceKind
{
    External,
    Project,
}

/// Ports `enum MediaSource { case external(absolutePath: String); case project(relativePath: String) }`.
/// Swift's SE-0295 enum-with-associated-values Codable synthesis encodes this as a single-key
/// object keyed by the case name, wrapping a nested object keyed by the associated label:
/// `{"external":{"absolutePath":"..."}}` or `{"project":{"relativePath":"..."}}`.
[JsonConverter(typeof(MediaSourceJsonConverter))]
public sealed class MediaSource : IEquatable<MediaSource>
{
    public MediaSourceKind Kind { get; }
    public string Path { get; }

    private MediaSource(MediaSourceKind kind, string path)
    {
        Kind = kind;
        Path = path;
    }

    public static MediaSource External(string absolutePath) => new(MediaSourceKind.External, absolutePath);
    public static MediaSource Project(string relativePath) => new(MediaSourceKind.Project, relativePath);

    public bool Equals(MediaSource? other) => other is not null && Kind == other.Kind && Path == other.Path;
    public override bool Equals(object? obj) => Equals(obj as MediaSource);
    public override int GetHashCode() => HashCode.Combine(Kind, Path);
}

public sealed class MediaSourceJsonConverter : JsonConverter<MediaSource>
{
    public override MediaSource Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;
        if (root.TryGetProperty("external", out var external))
        {
            return MediaSource.External(RequireString(external, "absolutePath"));
        }
        if (root.TryGetProperty("project", out var project))
        {
            return MediaSource.Project(RequireString(project, "relativePath"));
        }
        throw new JsonException("Unknown MediaSource case — expected 'external' or 'project'.");
    }

    private static string RequireString(JsonElement container, string property)
    {
        if (!container.TryGetProperty(property, out var element) || element.ValueKind != JsonValueKind.String)
        {
            throw new JsonException($"Missing or non-string '{property}' in MediaSource payload.");
        }
        return element.GetString()!;
    }

    public override void Write(Utf8JsonWriter writer, MediaSource value, JsonSerializerOptions options)
    {
        var (caseKey, propKey) = value.Kind == MediaSourceKind.External
            ? ("external", "absolutePath")
            : ("project", "relativePath");
        writer.WriteStartObject();
        writer.WritePropertyName(caseKey);
        writer.WriteStartObject();
        writer.WriteString(propKey, value.Path);
        writer.WriteEndObject();
        writer.WriteEndObject();
    }
}
