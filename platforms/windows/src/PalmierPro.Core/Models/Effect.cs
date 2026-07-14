using System.Text.Json;
using System.Text.Json.Serialization;
using PalmierPro.Core.Json;

namespace PalmierPro.Core.Models;

/// A single effect parameter. Swift's synthesized Codable makes all three properties
/// Optional-lenient (decodeIfPresent: missing key -> nil, wrong type -> throws) — the default
/// System.Text.Json object converter already behaves this way for nullable properties, so this
/// type needs no custom converter, just exact key names and null-omission on write.
public sealed class EffectParam
{
    [JsonPropertyName("value")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? Value { get; set; }

    [JsonPropertyName("string")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? StringValue { get; set; }

    [JsonPropertyName("track")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public KeyframeTrack<double>? Track { get; set; }

    public EffectParam()
    {
    }

    public EffectParam(double? value = null, string? stringValue = null, KeyframeTrack<double>? track = null)
    {
        Value = value;
        StringValue = stringValue;
        Track = track;
    }

    /// Effective numeric value at a clip-relative frame offset.
    public double Resolved(int offset, double defaultValue)
    {
        if (Track is { IsActive: true } track)
        {
            return track.Sample(offset, Value ?? defaultValue, KeyframeInterpolation.Double);
        }
        return Value ?? defaultValue;
    }
}

/// One entry in a clip's ordered effect stack.
[JsonConverter(typeof(EffectJsonConverter))]
public sealed class Effect
{
    public string Id { get; set; } = SwiftId.New();
    public string Type { get; set; }
    public bool Enabled { get; set; } = true;
    public Dictionary<string, EffectParam> Params { get; set; } = [];

    public Effect(string type)
    {
        Type = type;
    }

    public Effect(string id, string type, bool enabled, Dictionary<string, EffectParam> @params)
    {
        Id = id;
        Type = type;
        Enabled = enabled;
        Params = @params;
    }

    /// Convenience for static numeric params.
    public static Effect Make(string type, Dictionary<string, double>? values = null)
    {
        var effect = new Effect(type);
        if (values is not null)
        {
            foreach (var (key, value) in values)
            {
                effect.Params[key] = new EffectParam(value);
            }
        }
        return effect;
    }
}

public sealed class EffectJsonConverter : JsonConverter<Effect>
{
    public override Effect Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;
        return new Effect(
            id: LenientJson.TryOr(root, "id", options, SwiftId.New()),
            type: LenientJson.Require<string>(root, "type", options),
            enabled: LenientJson.TryOr(root, "enabled", options, true),
            @params: LenientJson.TryOr(root, "params", options, new Dictionary<string, EffectParam>())
        );
    }

    public override void Write(Utf8JsonWriter writer, Effect value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("id", value.Id);
        writer.WriteString("type", value.Type);
        writer.WriteBoolean("enabled", value.Enabled);
        writer.WritePropertyName("params");
        JsonSerializer.Serialize(writer, value.Params, options);
        writer.WriteEndObject();
    }
}
