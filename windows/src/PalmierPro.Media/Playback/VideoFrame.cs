namespace PalmierPro.Media;

/// <summary>A decoded BGRA frame ready for presentation.</summary>
public sealed record VideoFrame(byte[] Bgra, int Width, int Height, int Stride);

/// <summary>Receives decoded frames from the playback engine. Implementations own the
/// GPU/UI presentation and must tolerate calls from a decode thread.</summary>
public interface IFramePresenter
{
    void Present(VideoFrame frame);
    /// <summary>No video at the playhead (gap or audio-only region).</summary>
    void Clear();
}
