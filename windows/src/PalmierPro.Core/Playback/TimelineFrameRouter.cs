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
    /// <summary>Bounds nested-sequence recursion against reference cycles in corrupt projects.</summary>
    private const int MaxNestingDepth = 8;

    public static VideoFrameSource? VideoSourceAt(
        Timeline timeline, int frame,
        Func<string, Timeline?>? resolveSequence = null, int depth = 0)
    {
        for (var trackIndex = timeline.Tracks.Count - 1; trackIndex >= 0; trackIndex--)
        {
            var track = timeline.Tracks[trackIndex];
            if (track.Hidden || track.Type == ClipType.Audio) continue;
            foreach (var clip in track.Clips)
            {
                if (!clip.Contains(frame)) continue;

                if (clip.SourceClipType == ClipType.Sequence)
                {
                    if (resolveSequence is null || depth >= MaxNestingDepth) continue;
                    if (resolveSequence(clip.MediaRef) is not { } child) continue;
                    var childFrame = ChildFrameFor(clip, frame, timeline.Fps, child.Fps);
                    if (VideoSourceAt(child, childFrame, resolveSequence, depth + 1) is { } nested)
                        return nested;
                    continue;
                }

                if (clip.MediaType is not (ClipType.Video or ClipType.Image or ClipType.Lottie)) continue;
                return new VideoFrameSource(clip, SourceSecondsFor(clip, frame, timeline.Fps));
            }
        }
        return null;
    }

    /// <summary>Maps a parent-timeline frame inside a sequence clip to the child timeline's frame domain.</summary>
    public static int ChildFrameFor(Clip sequenceClip, int parentFrame, int parentFps, int childFps)
    {
        var sourceSeconds = SourceSecondsFor(sequenceClip, parentFrame, Math.Max(1, parentFps));
        return (int)Math.Round(sourceSeconds * Math.Max(1, childFps), MidpointRounding.AwayFromZero);
    }

    /// <summary>Maps a timeline frame inside the clip to seconds into the source media.</summary>
    public static double SourceSecondsFor(Clip clip, int timelineFrame, int fps)
    {
        if (fps <= 0) return 0;
        var elapsed = Math.Max(0, timelineFrame - clip.StartFrame);
        var sourceFrame = clip.TrimStartFrame + elapsed * clip.Speed;
        return sourceFrame / fps;
    }

    public static List<AudibleClip> AudibleClipsAt(
        Timeline timeline, int frame,
        Func<string, Timeline?>? resolveSequence = null, int depth = 0)
    {
        var audible = new List<AudibleClip>();
        foreach (var track in timeline.Tracks)
        {
            if (track.Muted) continue;
            foreach (var clip in track.Clips)
            {
                if (!clip.Contains(frame)) continue;

                if (clip.SourceClipType == ClipType.Sequence)
                {
                    if (resolveSequence is null || depth >= MaxNestingDepth) continue;
                    if (resolveSequence(clip.MediaRef) is not { } child) continue;
                    var childFrame = ChildFrameFor(clip, frame, timeline.Fps, child.Fps);
                    var carrierGain = clip.VolumeAt(frame);
                    if (carrierGain <= 0) continue;
                    foreach (var nested in AudibleClipsAt(child, childFrame, resolveSequence, depth + 1))
                        audible.Add(nested with { Gain = nested.Gain * carrierGain });
                    continue;
                }

                var carriesAudio = clip.MediaType is ClipType.Audio or ClipType.Video;
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
