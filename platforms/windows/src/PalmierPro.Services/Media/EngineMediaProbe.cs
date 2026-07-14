using PalmierPro.Core.Models;
using PalmierPro.Rendering;

namespace PalmierPro.Services.Media;

/// `IMediaProbe` implementation used by the Windows port: video/audio go through PalmierEngine
/// (`EngineSession.OpenMedia` + `MediaInfo` — the "Rendering probe"), images go through
/// <see cref="WicImaging"/> and never touch the engine. Lottie inspection isn't implemented until
/// Stage E's ThorVG bake lands; `ProbeLottieAsync` returning null surfaces the same way the Mac's
/// `try? LottieVideoGenerator.inspect` failing does — `MediaAsset.LoadMetadataAsync` reports the
/// asset unreadable, not a thrown exception.
public sealed class EngineMediaProbe(EngineSession session) : IMediaProbe
{
    public Task<ImageProbeResult?> ProbeImageAsync(string path) => WicImaging.ProbeImageAsync(path);

    public Task<VideoProbeResult?> ProbeVideoAsync(string path)
    {
        MediaInfo? info = TryGetInfo(path);
        if (info is null)
        {
            return Task.FromResult<VideoProbeResult?>(null);
        }
        return Task.FromResult<VideoProbeResult?>(new VideoProbeResult
        {
            HasVideoTrack = info.HasVideo,
            Width = info.HasVideo ? info.Width : null,
            Height = info.HasVideo ? info.Height : null,
            FrameRate = info.HasVideo && info.Fps > 0 ? info.Fps : null,
            VideoTrackDurationSeconds = info.HasVideo ? info.Duration.TotalSeconds : null,
        });
    }

    public Task<double?> ProbeAssetDurationAsync(string path) => Task.FromResult<double?>(TryGetInfo(path)?.Duration.TotalSeconds);

    public Task<bool?> HasAudioTrackAsync(string path) => Task.FromResult<bool?>(TryGetInfo(path)?.HasAudio);

    public Task<LottieProbeResult?> ProbeLottieAsync(string path) => Task.FromResult<LottieProbeResult?>(null);

    private MediaInfo? TryGetInfo(string path)
    {
        try
        {
            using Rendering.MediaSource media = session.OpenMedia(path);
            return media.Info;
        }
        catch (EngineException)
        {
            return null;
        }
    }
}
