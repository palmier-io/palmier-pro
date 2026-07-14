namespace PalmierPro.Core.Models;

/// Seam replacing the AVFoundation/ImageIO calls in MediaAsset.loadMetadata() (video/audio track
/// probing, image metadata, Lottie inspection). Core has no dependency on any concrete media
/// framework; a Windows FFmpeg-backed implementation lives in PalmierPro.Services. Every method
/// mirrors a Swift `try?` call — a thrown/failed probe surfaces as `null`, not an exception.
public interface IMediaProbe
{
    Task<ImageProbeResult?> ProbeImageAsync(string path);

    Task<VideoProbeResult?> ProbeVideoAsync(string path);

    /// Mirrors `try? await avAsset.load(.duration)`.
    Task<double?> ProbeAssetDurationAsync(string path);

    /// Mirrors `try? await avAsset.loadTracks(withMediaType: .audio)` collapsed to "has at least one".
    Task<bool?> HasAudioTrackAsync(string path);

    Task<LottieProbeResult?> ProbeLottieAsync(string path);
}

public sealed class ImageProbeResult
{
    public int? Width { get; set; }
    public int? Height { get; set; }
}

public sealed class VideoProbeResult
{
    public bool HasVideoTrack { get; set; }
    public int? Width { get; set; }
    public int? Height { get; set; }
    public double? FrameRate { get; set; }

    /// The video track's own `timeRange.duration`, when a track is present and it loaded.
    public double? VideoTrackDurationSeconds { get; set; }
}

public sealed class LottieProbeResult
{
    public double Duration { get; set; }
    public double Width { get; set; }
    public double Height { get; set; }
    public double FrameRate { get; set; }
}
