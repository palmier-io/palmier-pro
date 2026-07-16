using PalmierPro.Core.Models;
using PalmierPro.Rendering;

namespace PalmierPro.Services.Media;

/// `IMediaProbe` implementation used by the Windows port: video/audio go through PalmierEngine
/// (`EngineSession.OpenMedia` + `MediaInfo` — the "Rendering probe"), images go through
/// <see cref="WicImaging"/> and never touch the engine, Lottie goes through
/// <see cref="EngineSession.ProbeLottieMetadata"/> (native `PE_ProbeLottieMetadata` — ThorVG opens
/// the composition, no rasterization/encode/disk cache involved, docs/lottie-bake-v1.md §11). A
/// failed probe (corrupt/non-Lottie JSON, or a `.lottie` archive with no recognizable animation
/// entry) surfaces as null, the same way the Mac's `try? LottieVideoGenerator.inspect` failing does —
/// `MediaAsset.LoadMetadataAsync` reports the asset unreadable, not a thrown exception.
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

    public Task<LottieProbeResult?> ProbeLottieAsync(string path)
    {
        string jsonPath = path;
        string? extractDir = null;
        try
        {
            if (DotLottieExtractor.IsDotLottiePath(path))
            {
                extractDir = Path.Combine(Path.GetTempPath(), $"palmier-lottie-probe-{Guid.NewGuid():N}");
                jsonPath = DotLottieExtractor.Extract(path, extractDir, includeAssets: false);
            }
            LottieInfo info = session.ProbeLottieMetadata(jsonPath);
            return Task.FromResult<LottieProbeResult?>(new LottieProbeResult
            {
                Duration = info.DurationSeconds,
                Width = info.Width,
                Height = info.Height,
                FrameRate = info.FrameRate,
            });
        }
        catch (EngineException)
        {
            return Task.FromResult<LottieProbeResult?>(null);
        }
        catch (InvalidDataException)
        {
            return Task.FromResult<LottieProbeResult?>(null);
        }
        finally
        {
            if (extractDir is not null)
            {
                try
                {
                    Directory.Delete(extractDir, recursive: true);
                }
                catch (IOException)
                {
                }
                catch (UnauthorizedAccessException)
                {
                }
            }
        }
    }

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
