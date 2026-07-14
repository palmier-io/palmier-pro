using System.Text.Json;
using System.Text.Json.Serialization;
using PalmierPro.Core.Json;

namespace PalmierPro.Core.Models;

/// Data-only port of EditorViewModel+Cost.swift's GenerationLog — the project package's
/// generation-log.json. Full cost/generation-history UI is a Phase 2 AI-feature concern; only
/// the persisted shape is needed here for lossless project round-trip. No custom Swift decoder,
/// so — same gotcha as <see cref="Keyframe{T}"/> — both fields are REQUIRED on decode despite
/// having defaults; the defaults only apply to Swift-side construction.
public sealed class GenerationLog
{
    [JsonPropertyName("version")]
    [JsonRequired]
    public int Version { get; set; } = 1;

    [JsonPropertyName("entries")]
    [JsonRequired]
    public List<GenerationLogEntry> Entries { get; set; } = [];
}

/// One row in the Project Activity log. Synthesized Codable except for the legacy `cost`
/// (dollars, Double) -> `costCredits` (Int) migration, which needs a custom decoder. Unlike
/// Timeline/Track/Clip's `try? ... ?? default` leniency, every field here is either required or
/// plain `decodeIfPresent` (missing -> default, present-with-wrong-type -> throws).
[JsonConverter(typeof(GenerationLogEntryJsonConverter))]
public sealed class GenerationLogEntry
{
    public string Id { get; set; } = SwiftId.New();
    public string Model { get; set; } = "";
    public int? CostCredits { get; set; }
    public DateTimeOffset? CreatedAt { get; set; }

    public GenerationLogEntry()
    {
    }

    public GenerationLogEntry(string model, int? costCredits, DateTimeOffset? createdAt, string? id = null)
    {
        Id = id ?? SwiftId.New();
        Model = model;
        CostCredits = costCredits;
        CreatedAt = createdAt;
    }
}

public sealed class GenerationLogEntryJsonConverter : JsonConverter<GenerationLogEntry>
{
    public override GenerationLogEntry Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;

        var id = root.TryGetProperty("id", out var idEl) && idEl.ValueKind != JsonValueKind.Null
            ? RequireString(idEl, "id")
            : SwiftId.New();
        var model = LenientJson.Require<string>(root, "model", options);
        DateTimeOffset? createdAt = root.TryGetProperty("createdAt", out var createdAtEl) && createdAtEl.ValueKind != JsonValueKind.Null
            ? SwiftDate.FromReferenceSeconds(createdAtEl.GetDouble())
            : null;

        int? costCredits;
        if (root.TryGetProperty("costCredits", out var creditsEl) && creditsEl.ValueKind != JsonValueKind.Null)
        {
            costCredits = creditsEl.GetInt32();
        }
        else if (root.TryGetProperty("cost", out var costEl) && costEl.ValueKind != JsonValueKind.Null)
        {
            // Legacy entries stored `cost` in dollars; credits = ceil(dollars * 100).
            costCredits = (int)Math.Ceiling(costEl.GetDouble() * 100);
        }
        else
        {
            costCredits = null;
        }

        return new GenerationLogEntry(model, costCredits, createdAt, id);
    }

    private static string RequireString(JsonElement element, string property)
    {
        if (element.ValueKind != JsonValueKind.String)
        {
            throw new JsonException($"'{property}' expected a string.");
        }
        return element.GetString()!;
    }

    public override void Write(Utf8JsonWriter writer, GenerationLogEntry value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("id", value.Id);
        writer.WriteString("model", value.Model);
        if (value.CostCredits is { } costCredits)
        {
            writer.WriteNumber("costCredits", costCredits);
        }
        if (value.CreatedAt is { } createdAt)
        {
            writer.WriteNumber("createdAt", SwiftDate.ToReferenceSeconds(createdAt));
        }
        writer.WriteEndObject();
    }
}
