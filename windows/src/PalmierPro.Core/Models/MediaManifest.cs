using System.Text.Json;
using System.Text.Json.Serialization;

namespace PalmierPro.Core.Models;

[JsonConverter(typeof(MediaManifestJsonConverter))]
public sealed class MediaManifest
{
    /// <summary>New manifests are v2; decoding a file without a version key means v1 (pre-folders).</summary>
    public int Version { get; set; } = 2;
    public List<MediaManifestEntry> Entries { get; set; } = [];
    public List<MediaFolder> Folders { get; set; } = [];
}

/// <summary>Mirrors the Swift decoder: a missing version key decodes as 1, not the creation default of 2.</summary>
public sealed class MediaManifestJsonConverter : JsonConverter<MediaManifest>
{
    public override MediaManifest Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.StartObject) throw new JsonException();
        var manifest = new MediaManifest { Version = 1 };
        while (reader.Read() && reader.TokenType != JsonTokenType.EndObject)
        {
            var name = reader.GetString();
            reader.Read();
            switch (name)
            {
                case "version":
                    manifest.Version = reader.GetInt32();
                    break;
                case "entries":
                    manifest.Entries = JsonSerializer.Deserialize<List<MediaManifestEntry>>(ref reader, options) ?? [];
                    break;
                case "folders":
                    manifest.Folders = JsonSerializer.Deserialize<List<MediaFolder>>(ref reader, options) ?? [];
                    break;
                default:
                    reader.Skip();
                    break;
            }
        }
        return manifest;
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

public sealed class MediaManifestEntry
{
    public required string Id { get; set; }
    public required string Name { get; set; }
    public required ClipType Type { get; set; }
    public required MediaSource Source { get; set; }
    public double Duration { get; set; }
    public GenerationInput? GenerationInput { get; set; }
    public int? SourceWidth { get; set; }
    public int? SourceHeight { get; set; }
    public double? SourceFPS { get; set; }
    public bool? HasAudio { get; set; }
    public string? FolderId { get; set; }
    public string? CachedRemoteURL { get; set; }
    public DateTime? CachedRemoteURLExpiresAt { get; set; }
    public string? GenerationStatus { get; set; }
    public MediaImportInput? ImportInput { get; set; }
}

public sealed class MediaImportInput
{
    public string? SourceURL { get; set; }
    public string? SourcePath { get; set; }
    public DateTime? CreatedAt { get; set; }
}

public sealed class GenerationInput
{
    public required string Prompt { get; set; }
    public required string Model { get; set; }
    public int Duration { get; set; }
    public required string AspectRatio { get; set; }
    public string? Resolution { get; set; }
    public UpscaleSettings? UpscaleSettings { get; set; }
    public int? UpscaleSourceWidth { get; set; }
    public int? UpscaleSourceHeight { get; set; }
    public double? UpscaleSourceFPS { get; set; }
    public string? Quality { get; set; }
    public List<string>? ImageURLs { get; set; }
    /// <summary>Image-only.</summary>
    public int? NumImages { get; set; }
    /// <summary>Audio-only.</summary>
    public string? Voice { get; set; }
    public string? Lyrics { get; set; }
    public string? StyleInstructions { get; set; }
    public bool? Instrumental { get; set; }
    public string? TargetLanguage { get; set; }
    public bool? Multilingual { get; set; }
    public string? AudioInput { get; set; }
    /// <summary>Video-only.</summary>
    public bool? GenerateAudio { get; set; }
    public List<string>? ReferenceImageURLs { get; set; }
    public List<string>? ReferenceVideoURLs { get; set; }
    public List<string>? ReferenceAudioURLs { get; set; }

    // Asset IDs for the references.
    public List<string>? ImageURLAssetIds { get; set; }
    public List<string>? ReferenceImageAssetIds { get; set; }
    public List<string>? ReferenceVideoAssetIds { get; set; }
    public List<string>? ReferenceAudioAssetIds { get; set; }
    public DateTime? CreatedAt { get; set; }
    public string? BackendJobId { get; set; }
    public int? OutputIndex { get; set; }
    public List<string>? ResultURLs { get; set; }
}

/// <summary>
/// Placeholder mirroring the Swift UpscaleSettings payload; refined with the Generation phase.
/// Preserved losslessly so round-tripping a manifest never drops fields.
/// </summary>
[JsonConverter(typeof(RawJsonConverter<UpscaleSettings>))]
public sealed class UpscaleSettings : IRawJsonCarrier
{
    public JsonElement Raw { get; set; }
}

public interface IRawJsonCarrier
{
    JsonElement Raw { get; set; }
}

/// <summary>Round-trips unknown JSON payloads without interpreting them.</summary>
public sealed class RawJsonConverter<T> : JsonConverter<T> where T : IRawJsonCarrier, new()
{
    public override T Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        => new() { Raw = JsonElement.ParseValue(ref reader) };

    public override void Write(Utf8JsonWriter writer, T value, JsonSerializerOptions options)
        => value.Raw.WriteTo(writer);
}

[JsonConverter(typeof(MediaSourceJsonConverter))]
public abstract record MediaSource
{
    public sealed record External(string AbsolutePath) : MediaSource;
    public sealed record Project(string RelativePath) : MediaSource;
}

/// <summary>
/// Swift enum-with-associated-values encoding:
/// {"external":{"absolutePath":"..."}} or {"project":{"relativePath":"..."}}.
/// </summary>
public sealed class MediaSourceJsonConverter : JsonConverter<MediaSource>
{
    public override MediaSource Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;
        if (root.TryGetProperty("external", out var external)
            && external.TryGetProperty("absolutePath", out var absolute))
        {
            return new MediaSource.External(absolute.GetString() ?? "");
        }
        if (root.TryGetProperty("project", out var project)
            && project.TryGetProperty("relativePath", out var relative))
        {
            return new MediaSource.Project(relative.GetString() ?? "");
        }
        throw new JsonException("Unrecognized MediaSource payload");
    }

    public override void Write(Utf8JsonWriter writer, MediaSource value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        switch (value)
        {
            case MediaSource.External external:
                writer.WriteStartObject("external");
                writer.WriteString("absolutePath", external.AbsolutePath);
                writer.WriteEndObject();
                break;
            case MediaSource.Project project:
                writer.WriteStartObject("project");
                writer.WriteString("relativePath", project.RelativePath);
                writer.WriteEndObject();
                break;
            default:
                throw new JsonException("Unknown MediaSource case");
        }
        writer.WriteEndObject();
    }
}
