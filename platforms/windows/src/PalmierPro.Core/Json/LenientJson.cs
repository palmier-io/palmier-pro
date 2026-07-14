using System.Text.Json;

namespace PalmierPro.Core.Json;

/// Shared helpers for hand-written converters that replicate Swift's `try c.decode(...)`
/// (required, throws) and `(try? c.decode(...)) ?? default` (lenient, swallows both missing-key
/// AND type-mismatch errors, including from nested decode failures) patterns exactly.
public static class LenientJson
{
    public static T Require<T>(JsonElement root, string property, JsonSerializerOptions options)
    {
        if (!root.TryGetProperty(property, out var element))
        {
            throw new JsonException($"Missing required '{property}'.");
        }
        var value = element.Deserialize<T>(options);
        return value is null ? throw new JsonException($"'{property}' decoded to null.") : value;
    }

    /// Mirrors `(try? c.decode(...)) ?? fallback`.
    public static T TryOr<T>(JsonElement root, string property, JsonSerializerOptions options, T fallback)
    {
        if (!root.TryGetProperty(property, out var element))
        {
            return fallback;
        }
        try
        {
            var value = element.Deserialize<T>(options);
            return value is null ? fallback : value;
        }
        catch (JsonException)
        {
            return fallback;
        }
    }

    /// Mirrors `try c.decodeIfPresent(...) ?? fallback`: the fallback applies ONLY when the key
    /// is absent or JSON `null`. Unlike <see cref="TryOr{T}"/>, a present-but-wrong-typed value
    /// (or a nested element that fails to decode) is NOT swallowed — it throws, matching Swift's
    /// non-lenient `decodeIfPresent` semantics.
    public static T PresentOr<T>(JsonElement root, string property, JsonSerializerOptions options, T fallback)
    {
        if (!root.TryGetProperty(property, out var element) || element.ValueKind == JsonValueKind.Null)
        {
            return fallback;
        }
        var value = element.Deserialize<T>(options);
        return value is null ? fallback : value;
    }

    /// Mirrors `try? c.decode(...)` assigned straight to an Optional reference-typed property —
    /// nil on any failure. Split from <see cref="TryOrNullValue{T}"/> because an UNCONSTRAINED
    /// generic `T?` erases to plain `T` for value-type instantiations (confirmed empirically —
    /// `TryOrNull{double}` would silently return `0.0`, not null, on a missing key): only a
    /// `where T : class`/`where T : struct` split gives a real `Nullable<T>` for value types.
    public static T? TryOrNull<T>(JsonElement root, string property, JsonSerializerOptions options) where T : class
    {
        if (!root.TryGetProperty(property, out var element))
        {
            return null;
        }
        try
        {
            return element.Deserialize<T>(options);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// Value-type counterpart of <see cref="TryOrNull{T}"/> — see its doc comment for why this
    /// split exists.
    public static T? TryOrNullValue<T>(JsonElement root, string property, JsonSerializerOptions options) where T : struct
    {
        if (!root.TryGetProperty(property, out var element))
        {
            return null;
        }
        try
        {
            return element.Deserialize<T>(options);
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
