using System.Text.Json;
using System.Text.Json.Serialization;

namespace PalmierPro.Core.Models;

/// Data-only port of `EditorViewModel+Speakers.swift`'s `SpeakerRegistryEntry` — needed only so
/// `ProjectFile.speakers` round-trips losslessly. Full speaker identification (on-device AI) is
/// Phase 3. No custom Swift decoder, so every field is required on decode.
public sealed class SpeakerRegistryEntry
{
    [JsonPropertyName("id")]
    [JsonRequired]
    public int Id { get; set; }

    [JsonPropertyName("name")]
    [JsonRequired]
    public string Name { get; set; } = "";

    [JsonPropertyName("color")]
    [JsonRequired]
    public List<double> Color { get; set; } = [];

    [JsonPropertyName("centroid")]
    [JsonRequired]
    public List<float> Centroid { get; set; } = [];
}

/// Root of project.json. Legacy projects stored a bare Timeline; <see cref="Decode"/> falls back
/// and wraps. No custom Swift encoder — `Timelines` is required, everything else Optional
/// (missing/null -> omitted on write, via `encodeIfPresent`/`decodeIfPresent`).
public sealed class ProjectFile
{
    [JsonPropertyName("timelines")]
    [JsonRequired]
    public List<Timeline> Timelines { get; set; } = [];

    [JsonPropertyName("activeTimelineId")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ActiveTimelineId { get; set; }

    [JsonPropertyName("openTimelineIds")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<string>? OpenTimelineIds { get; set; }

    [JsonPropertyName("viewStates")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public Dictionary<string, TimelineViewState>? ViewStates { get; set; }

    [JsonPropertyName("speakers")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<SpeakerRegistryEntry>? Speakers { get; set; }

    [JsonPropertyName("multicamGroups")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<MulticamSource>? MulticamGroups { get; set; }

    public ProjectFile()
    {
    }

    public ProjectFile(
        List<Timeline> timelines, string? activeTimelineId = null, List<string>? openTimelineIds = null,
        Dictionary<string, TimelineViewState>? viewStates = null, List<SpeakerRegistryEntry>? speakers = null,
        List<MulticamSource>? multicamGroups = null)
    {
        Timelines = timelines;
        ActiveTimelineId = activeTimelineId;
        OpenTimelineIds = openTimelineIds;
        ViewStates = viewStates;
        Speakers = speakers;
        MulticamGroups = multicamGroups;
    }

    /// Mirrors `ProjectFile.decode(_:)`: tries the multi-timeline shape first (also rejecting an
    /// explicit empty `timelines` array, same as the Swift `dataCorrupted` guard); a legacy
    /// bare-Timeline document falls back and wraps into a single-timeline project. If the legacy
    /// decode ALSO fails, the ORIGINAL error is rethrown, not the legacy one.
    public static ProjectFile Decode(byte[] data)
    {
        JsonException? originalError;
        try
        {
            var file = JsonSerializer.Deserialize<ProjectFile>(data);
            if (file is not null && file.Timelines is { Count: > 0 })
            {
                return file;
            }
            originalError = new JsonException("project has no timelines");
        }
        catch (JsonException ex)
        {
            originalError = ex;
        }

        Timeline? legacy;
        try
        {
            legacy = JsonSerializer.Deserialize<Timeline>(data);
        }
        catch (JsonException)
        {
            legacy = null;
        }
        if (legacy is null)
        {
            throw originalError;
        }
        return new ProjectFile([legacy], legacy.Id, [legacy.Id]);
    }
}
