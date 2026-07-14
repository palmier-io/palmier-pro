using System.Text.Json;
using System.Text.Json.Serialization;

namespace PalmierPro.Core.Json;

/// Swift's default (`.deferredToDate`) JSONEncoder/JSONDecoder strategy encodes `Date` as a
/// single Double of seconds since the Cocoa reference date (2001-01-01T00:00:00Z) — NOT the Unix
/// epoch. The project/media/generation-log JSON files never set `dateEncodingStrategy`, so every
/// `Date` field in this cluster goes through this shared conversion.
public static class SwiftDate
{
    public static readonly DateTimeOffset ReferenceDate = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);

    public static DateTimeOffset FromReferenceSeconds(double seconds) => ReferenceDate.AddSeconds(seconds);

    public static double ToReferenceSeconds(DateTimeOffset value) => (value - ReferenceDate).TotalSeconds;
}

public sealed class SwiftDateJsonConverter : JsonConverter<DateTimeOffset>
{
    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        SwiftDate.FromReferenceSeconds(reader.GetDouble());

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
        writer.WriteNumberValue(SwiftDate.ToReferenceSeconds(value));
}
