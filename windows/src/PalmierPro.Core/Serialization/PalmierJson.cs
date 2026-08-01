using System.Text.Json;
using System.Text.Json.Serialization;

namespace PalmierPro.Core.Serialization;

/// <summary>
/// JSON configuration matching Swift's JSONEncoder/JSONDecoder as used by the macOS app:
/// camelCase keys, nil optionals omitted, enums as camelCase case names,
/// dates as seconds since the Apple reference date (2001-01-01T00:00:00Z).
/// </summary>
public static class PalmierJson
{
    public static readonly JsonSerializerOptions Options = Create();

    private static JsonSerializerOptions Create()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            IncludeFields = false,
            ReadCommentHandling = JsonCommentHandling.Skip,
            AllowTrailingCommas = true,
        };
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        options.Converters.Add(new AppleReferenceDateConverter());
        options.Converters.Add(new NullableAppleReferenceDateConverter());
        return options;
    }

    public static byte[] Encode<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, Options);

    public static string EncodeToString<T>(T value) => JsonSerializer.Serialize(value, Options);

    public static T? Decode<T>(ReadOnlySpan<byte> data)
        => JsonSerializer.Deserialize<T>(StripBom(data), Options);

    public static T? Decode<T>(string json) => JsonSerializer.Deserialize<T>(json, Options);

    /// <summary>Utf8JsonReader rejects a UTF-8 BOM; tolerate files saved by BOM-writing editors.</summary>
    private static ReadOnlySpan<byte> StripBom(ReadOnlySpan<byte> data)
        => data.Length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF ? data[3..] : data;
}

/// <summary>Generates identifiers matching Swift's UUID().uuidString (uppercase hyphenated).</summary>
public static class Uuid
{
    public static string NewString() => Guid.NewGuid().ToString("D").ToUpperInvariant();
}
