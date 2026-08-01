using NAudio.Wave;
using PalmierPro.Core;
using PalmierPro.Core.Models;
using PalmierPro.Media.Video;
using Vortice.MediaFoundation;

namespace PalmierPro.Media;

/// <summary>
/// Off-UI probe of duration / size / audio presence for import and placement.
/// </summary>
public static class MediaMetadataProbe
{
    public sealed record Result(
        double DurationSeconds,
        int? Width,
        int? Height,
        bool? HasAudio,
        double? SourceFps);

    public static Result Probe(string path, ClipType type)
    {
        MediaFoundationSession.EnsureStarted();
        return type switch
        {
            ClipType.Image => ProbeImage(path),
            ClipType.Audio => ProbeAudio(path),
            ClipType.Video or ClipType.Sequence => ProbeVideo(path),
            _ => new Result(0, null, null, null, null),
        };
    }

    /// <summary>Writes probe fields onto a runtime asset when values are still unset/zero.</summary>
    public static void Apply(MediaAsset asset)
    {
        if (asset.Url is not { Length: > 0 } path || !File.Exists(path)) return;
        try
        {
            var result = Probe(path, asset.Type);
            if (asset.Duration <= 0 && result.DurationSeconds > 0)
                asset.Duration = result.DurationSeconds;
            if (asset.SourceWidth is null && result.Width is { } w) asset.SourceWidth = w;
            if (asset.SourceHeight is null && result.Height is { } h) asset.SourceHeight = h;
            if (asset.SourceFPS is null && result.SourceFps is { } fps) asset.SourceFPS = fps;
            if (asset.HasAudio is null && result.HasAudio is { } audio) asset.HasAudio = audio;
        }
        catch
        {
            // Best-effort; placement falls back to defaults.
        }
    }

    private static Result ProbeImage(string path)
    {
        int? width = null, height = null;
        try
        {
            using var image = System.Drawing.Image.FromFile(path);
            width = image.Width;
            height = image.Height;
        }
        catch { /* size optional */ }

        return new Result(EditorDefaults.ImageDurationSeconds, width, height, HasAudio: false, SourceFps: null);
    }

    private static Result ProbeAudio(string path)
    {
        using var reader = new MediaFoundationReader(path);
        var duration = reader.TotalTime.TotalSeconds;
        return new Result(
            double.IsFinite(duration) && duration > 0 ? duration : 0,
            null, null, HasAudio: true, SourceFps: null);
    }

    private static Result ProbeVideo(string path)
    {
        using var extractor = new VideoFrameExtractor(path);
        var duration = extractor.DurationSeconds;
        if (!double.IsFinite(duration) || duration < 0) duration = 0;
        return new Result(
            duration,
            extractor.NativeWidth > 0 ? extractor.NativeWidth : null,
            extractor.NativeHeight > 0 ? extractor.NativeHeight : null,
            ProbeHasAudio(path),
            SourceFps: null);
    }

    private static bool ProbeHasAudio(string path)
    {
        try
        {
            using var attributes = MediaFactory.MFCreateAttributes(1);
            attributes.Set(SourceReaderAttributeKeys.EnableAdvancedVideoProcessing, true);
            using var reader = MediaFactory.MFCreateSourceReaderFromURL(path, attributes);
            reader.SetStreamSelection(SourceReaderIndex.AllStreams, false);
            try
            {
                reader.SetStreamSelection(SourceReaderIndex.FirstAudioStream, true);
                using var type = reader.GetCurrentMediaType(SourceReaderIndex.FirstAudioStream);
                return type is not null;
            }
            catch
            {
                return false;
            }
        }
        catch
        {
            return true; // Prefer linked audio; mixer no-ops if the file is silent.
        }
    }
}
