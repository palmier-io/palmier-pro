using System.Text.Json;

namespace PalmierPro.Agent.Tools;

internal static class ToolArgs
{
    public static string? String(JsonElement args, string key)
        => args.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    public static bool? Bool(JsonElement args, string key)
        => args.TryGetProperty(key, out var v) && (v.ValueKind is JsonValueKind.True or JsonValueKind.False)
            ? v.GetBoolean() : null;

    public static int? Int(JsonElement args, string key)
    {
        if (!args.TryGetProperty(key, out var v)) return null;
        if (v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var i)) return i;
        if (v.ValueKind == JsonValueKind.Number && v.TryGetDouble(out var d)) return (int)Math.Round(d);
        return null;
    }

    public static double? Number(JsonElement args, string key)
        => args.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : null;

    public static IReadOnlyList<string> StringArray(JsonElement args, string key)
    {
        if (!args.TryGetProperty(key, out var v) || v.ValueKind != JsonValueKind.Array) return [];
        return v.EnumerateArray()
            .Where(e => e.ValueKind == JsonValueKind.String)
            .Select(e => e.GetString()!)
            .ToList();
    }

    public static IReadOnlyList<int> IntArray(JsonElement args, string key)
    {
        if (!args.TryGetProperty(key, out var v) || v.ValueKind != JsonValueKind.Array) return [];
        var list = new List<int>();
        foreach (var e in v.EnumerateArray())
        {
            if (e.ValueKind == JsonValueKind.Number && e.TryGetInt32(out var i)) list.Add(i);
        }
        return list;
    }

    public static JsonElement? Array(JsonElement args, string key)
        => args.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Array ? v : null;
}
