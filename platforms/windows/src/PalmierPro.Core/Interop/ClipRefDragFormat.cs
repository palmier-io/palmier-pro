using System.Text.Json;

namespace PalmierPro.Core.Interop;

/// Wire contract for dragging one or more media assets out of the media panel. Custom clipboard/
/// drag-drop format name plus its JSON payload shape — both the media panel (drag source, Stage B)
/// and the timeline (drop target, Stage C) reference this class rather than duplicating either the
/// format string or the payload shape.
public static class ClipRefDragFormat
{
    /// DataPackage/DataView format id — pass to SetData/Contains/GetDataAsync.
    public const string FormatId = "PalmierPro.ClipRef";

    public static string Serialize(IReadOnlyList<string> assetIds) =>
        JsonSerializer.Serialize(new ClipRefPayload(assetIds));

    /// Null on malformed JSON — callers treat that the same as "not a ClipRef drag."
    public static IReadOnlyList<string>? Deserialize(string json)
    {
        try
        {
            return JsonSerializer.Deserialize<ClipRefPayload>(json)?.AssetIds;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

public sealed record ClipRefPayload(IReadOnlyList<string> AssetIds);
