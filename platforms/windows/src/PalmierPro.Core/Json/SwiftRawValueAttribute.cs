namespace PalmierPro.Core.Json;

/// Tags an enum member with its Swift `String` raw value when it differs from the C# member name
/// (e.g. Swift's snake_case or lowerCamelCase raw values vs. C#'s PascalCase member names).
[AttributeUsage(AttributeTargets.Field)]
public sealed class SwiftRawValueAttribute(string value) : Attribute
{
    public string Value { get; } = value;
}
