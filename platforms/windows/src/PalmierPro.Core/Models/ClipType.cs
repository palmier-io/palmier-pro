using System.Text.Json.Serialization;
using PalmierPro.Core.Json;

namespace PalmierPro.Core.Models;

[JsonConverter(typeof(SwiftStringEnumConverter<ClipType>))]
public enum ClipType
{
    [SwiftRawValue("video")] Video,
    [SwiftRawValue("audio")] Audio,
    [SwiftRawValue("image")] Image,
    [SwiftRawValue("text")] Text,
    [SwiftRawValue("lottie")] Lottie,
    [SwiftRawValue("sequence")] Sequence,
}

public static class ClipTypeExtensions
{
    public static string TrackLabel(this ClipType type) => type switch
    {
        ClipType.Video => "Video",
        ClipType.Audio => "Audio",
        ClipType.Image => "Image",
        ClipType.Text => "Text",
        ClipType.Lottie => "Lottie",
        ClipType.Sequence => "Video",
        _ => throw new ArgumentOutOfRangeException(nameof(type)),
    };

    public static string TrackLabelPrefix(this ClipType type) => type.TrackLabel()[..1];

    public static bool IsVisual(this ClipType type) => type != ClipType.Audio;

    public static bool IsCompatible(this ClipType type, ClipType other) =>
        type == other || (type.IsVisual() && other.IsVisual());

    /// Mirrors Swift's `ClipType.init?(fileExtension:)`.
    public static bool TryFromFileExtension(string ext, out ClipType type)
    {
        switch (ext)
        {
            case "mov" or "mp4" or "m4v": type = ClipType.Video; return true;
            case "mp3" or "wav" or "aac" or "m4a" or "aiff" or "aif" or "aifc" or "flac": type = ClipType.Audio; return true;
            case "png" or "jpg" or "jpeg" or "tiff" or "heic" or "webp": type = ClipType.Image; return true;
            case "json" or "lottie": type = ClipType.Lottie; return true;
            default: type = default; return false;
        }
    }
}
