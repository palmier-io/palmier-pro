namespace PalmierPro.Core.Models;

public enum ClipType
{
    Video,
    Audio,
    Image,
    Text,
    Lottie,
    Sequence,
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
        _ => "Video",
    };

    public static string TrackLabelPrefix(this ClipType type) => type.TrackLabel()[..1];

    public static bool IsVisual(this ClipType type) => type != ClipType.Audio;

    public static bool IsCompatible(this ClipType type, ClipType other)
        => type == other || (type.IsVisual() && other.IsVisual());

    public static ClipType? FromFileExtension(string ext) => ext.ToLowerInvariant() switch
    {
        "mov" or "mp4" or "m4v" => ClipType.Video,
        "mp3" or "wav" or "aac" or "m4a" or "aiff" or "aif" or "aifc" or "caf" or "flac" => ClipType.Audio,
        "png" or "jpg" or "jpeg" or "tiff" or "heic" or "webp" => ClipType.Image,
        "json" or "lottie" => ClipType.Lottie,
        _ => null,
    };
}
