using System.Text.Json;

namespace PalmierPro.App.Editor;

/// <summary>In-app drag payload for media library → timeline drops.</summary>
internal static class MediaDragPayload
{
    public const string TextPrefix = "palmier-media-refs:";

    public static string Encode(IEnumerable<string> mediaRefs)
        => TextPrefix + JsonSerializer.Serialize(mediaRefs.Where(r => !string.IsNullOrWhiteSpace(r)).ToArray());

    public static bool TryDecode(string? text, out IReadOnlyList<string> mediaRefs)
    {
        mediaRefs = [];
        if (string.IsNullOrWhiteSpace(text) || !text.StartsWith(TextPrefix, StringComparison.Ordinal))
            return false;
        try
        {
            var json = text[TextPrefix.Length..];
            var ids = JsonSerializer.Deserialize<string[]>(json);
            if (ids is null || ids.Length == 0) return false;
            mediaRefs = ids;
            return true;
        }
        catch
        {
            return false;
        }
    }
}
