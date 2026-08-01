using System.Text.Json;
using PalmierPro.Core.Serialization;

namespace PalmierPro.Core.Models;

/// <summary>Root of project.json. Legacy projects stored a bare Timeline; decode falls back and wraps.</summary>
public sealed class ProjectFile
{
    public required List<Timeline> Timelines { get; set; }
    public string? ActiveTimelineId { get; set; }
    public List<string>? OpenTimelineIds { get; set; }
    public Dictionary<string, TimelineViewState>? ViewStates { get; set; }
    public List<SpeakerRegistryEntry>? Speakers { get; set; }
    public List<MulticamSource>? MulticamGroups { get; set; }

    public static ProjectFile Decode(ReadOnlySpan<byte> data)
    {
        try
        {
            var file = PalmierJson.Decode<ProjectFile>(data);
            if (file is { Timelines.Count: > 0 }) return file;
            throw new JsonException("project has no timelines");
        }
        catch (Exception)
        {
            // Legacy files are a bare Timeline; anything else rethrows the real error.
            Timeline? legacy = null;
            try
            {
                using var doc = JsonDocument.Parse(data.ToArray());
                if (doc.RootElement.ValueKind == JsonValueKind.Object
                    && doc.RootElement.TryGetProperty("tracks", out _)
                    && doc.RootElement.TryGetProperty("fps", out _))
                {
                    legacy = PalmierJson.Decode<Timeline>(data);
                }
            }
            catch
            {
                // fall through to rethrow the original error
            }
            if (legacy is null) throw;
            return new ProjectFile
            {
                Timelines = [legacy],
                ActiveTimelineId = legacy.Id,
                OpenTimelineIds = [legacy.Id],
            };
        }
    }
}

public sealed class SpeakerRegistryEntry
{
    public required int Id { get; set; }
    public required string Name { get; set; }
    public required List<double> Color { get; set; }
    public required List<float> Centroid { get; set; }
}
