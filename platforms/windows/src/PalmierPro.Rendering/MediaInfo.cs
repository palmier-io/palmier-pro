namespace PalmierPro.Rendering;

public enum PixelFormatClass
{
    Unknown = 0,
    Yuv420 = 1,
    Yuv422 = 2,
    Yuv444 = 3,
    Rgb = 4,
    Other = 5,
}

public sealed record MediaInfo(
    TimeSpan Duration,
    int FpsNumerator,
    int FpsDenominator,
    int Width,
    int Height,
    PixelFormatClass PixelFormat,
    int AudioChannels,
    int AudioSampleRate,
    bool HasVideo,
    bool HasAudio,
    bool HasAlpha)
{
    public double Fps => FpsDenominator == 0 ? 0 : (double)FpsNumerator / FpsDenominator;

    internal static MediaInfo FromNative(in PE_MediaInfo info) => new(
        TimeSpan.FromSeconds(info.DurationSeconds),
        info.FpsNumerator,
        info.FpsDenominator,
        info.Width,
        info.Height,
        (PixelFormatClass)info.PixelFormatClass,
        info.AudioChannels,
        info.AudioSampleRate,
        info.HasVideo != 0,
        info.HasAudio != 0,
        info.HasAlpha != 0);
}

/// <see cref="Bgra"/> aliases the source <see cref="MediaSource"/>'s reusable decode buffer — like
/// the native PE_FrameBuffer it wraps, it stays valid only until that same source's next
/// DecodeFrameAt call (or its disposal). Copy it out before decoding another frame if you need to
/// hold two decoded frames at once.
public readonly record struct DecodedFrame(ReadOnlyMemory<byte> Bgra, int Width, int Height, int StrideBytes);

public readonly record struct ThumbnailResult(int Index, double RequestedTimeSeconds, byte[] Bgra, int Width, int Height, int StrideBytes);
