using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PalmierPro.Core.Json;

/// Serializes an enum using its Swift `String` raw value (from <see cref="SwiftRawValueAttribute"/>,
/// falling back to the member name) instead of the C# member name. Also exposes the raw-value
/// lookup as static helpers for Swift enums that aren't Codable but still need `rawValue`/`init?(rawValue:)`
/// parity (e.g. VideoLayout, MatteAspect).
public sealed class SwiftStringEnumConverter<TEnum> : JsonConverter<TEnum> where TEnum : struct, Enum
{
    private static readonly Dictionary<string, TEnum> FromRaw = new(StringComparer.Ordinal);
    private static readonly Dictionary<TEnum, string> ToRaw = new();

    static SwiftStringEnumConverter()
    {
        foreach (var field in typeof(TEnum).GetFields(BindingFlags.Public | BindingFlags.Static))
        {
            var value = (TEnum)field.GetValue(null)!;
            var raw = field.GetCustomAttribute<SwiftRawValueAttribute>()?.Value ?? field.Name;
            FromRaw[raw] = value;
            ToRaw[value] = raw;
        }
    }

    public override TEnum Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var raw = reader.GetString();
        if (raw is not null && FromRaw.TryGetValue(raw, out var value))
        {
            return value;
        }
        throw new JsonException($"Unknown {typeof(TEnum).Name} raw value '{raw}'.");
    }

    public override void Write(Utf8JsonWriter writer, TEnum value, JsonSerializerOptions options)
    {
        writer.WriteStringValue(ToRaw[value]);
    }

    /// Mirrors Swift's `init?(rawValue:)` — case-sensitive, no trimming.
    public static bool TryParse(string raw, out TEnum value) => FromRaw.TryGetValue(raw, out value);

    /// Mirrors Swift's `.rawValue`.
    public static string RawValue(TEnum value) => ToRaw[value];
}
