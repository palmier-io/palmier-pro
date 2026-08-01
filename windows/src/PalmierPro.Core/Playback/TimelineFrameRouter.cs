using PalmierPro.Core.Models;

namespace PalmierPro.Core.Playback;

/// <summary>The clip and source-media position that supplies video for a timeline frame.</summary>
public sealed record VideoFrameSource(Clip Clip, double SourceSeconds);

/// <summary>An audible clip at a frame with its mixed gain (static × keyframes × fades).</summary>
public sealed record AudibleClip(Clip Clip, double Gain, double SourceSeconds);

/// <summary>
/// Pure timeline → source-media routing shared by playback, scrub, and frame capture.
/// Later tracks in the array stack on top, so the preview picks the topmost visible
/// visual clip.
/// </summary>
public static class TimelineFrameRouter
{
    public static VideoFrameSource? VideoSourceAt(Timeline timeline, int frame)
    {
        for (var trackIndex = timeline.Tracks.Count - 1; trackIndex >= 0; trackIndex--)
        {
            var track = timeline.Tracks[trackIndex];
            if (track.Hidden || track.Type == ClipType.Audio) continue;
            foreach (var clip in track.Clips)
            {
                if (!clip.Contains(frame)) continue;
                if (clip.MediaType is not (ClipType.Video or ClipType.Image or ClipType.Lottie)) continue;
                return new VideoFrameSource(clip, SourceSecondsFor(clip, frame, timeline.Fps));
            }
        }
        return null;
    }

    /// <summary>Maps a timeline frame inside the clip to seconds into the source media.</summary>
    public static double SourceSecondsFor(Clip clip, int timelineFrame, int fps)
    {
        if (fps <= 0) return 0;
        var elapsed = Math.Max(0, timelineFrame - clip.StartFrame);
        var sourceFrame = clip.TrimStartFrame + elapsed * clip.Speed;
        return sourceFrame / fps;
    }

    public static List<AudibleClip> AudibleClipsAt(Timeline timeline, int frame)
    {
        var audible = new List<AudibleClip>();
        foreach (var track in timeline.Tracks)
        {
            if (track.Muted) continue;
            foreach (var clip in track.Clips)
            {
                if (!clip.Contains(frame)) continue;
                var carriesAudio = clip.MediaType == ClipType.Audio
                    || (clip.MediaType == ClipType.Video && clip.SourceClipType != ClipType.Sequence);
                if (!carriesAudio) continue;
                var gain = clip.VolumeAt(frame);
                if (gain <= 0) continue;
                audible.Add(new AudibleClip(clip, gain, SourceSecondsFor(clip, frame, timeline.Fps)));
            }
        }
        return audible;
    }

    /// <summary>Total content duration in frames across all tracks.</summary>
    public static int DurationFrames(Timeline timeline)
    {
        var duration = 0;
        foreach (var track in timeline.Tracks)
            foreach (var clip in track.Clips)
                duration = Math.Max(duration, clip.EndFrame);
        return duration;
    }
}
