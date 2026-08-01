using System.Text.Json;
using System.Text.Json.Serialization;

namespace PalmierPro.Core.Serialization;

/// <summary>
/// Swift's JSONEncoder default date strategy: Double seconds since 2001-01-01T00:00:00Z.
/// </summary>
public sealed class AppleReferenceDateConverter : JsonConverter<DateTime>
{
    internal static readonly DateTime ReferenceDate = new(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    public override DateTime Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        => ReferenceDate.AddSeconds(reader.GetDouble());

    public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions options)
        => writer.WriteNumberValue((value.ToUniversalTime() - ReferenceDate).TotalSeconds);
}

public sealed class NullableAppleReferenceDateConverter : JsonConverter<DateTime?>
{
    public override DateTime? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        => reader.TokenType == JsonTokenType.Null
            ? null
            : AppleReferenceDateConverter.ReferenceDate.AddSeconds(reader.GetDouble());

    public override void Write(Utf8JsonWriter writer, DateTime? value, JsonSerializerOptions options)
    {
        if (value is { } date)
        {
            writer.WriteNumberValue((date.ToUniversalTime() - AppleReferenceDateConverter.ReferenceDate).TotalSeconds);
        }
        else
        {
            writer.WriteNullValue();
        }
    }
}
