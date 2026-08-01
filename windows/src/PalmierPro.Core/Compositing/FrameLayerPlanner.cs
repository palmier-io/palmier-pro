using PalmierPro.Core.Models;
using PalmierPro.Core.Playback;

namespace PalmierPro.Core.Compositing;

public enum FrameLayerKind
{
    Media,
    Text,
    Group,
}

/// <summary>
/// One visual layer at a specific frame, bottom → top. Media layers carry the
/// source time to decode; group layers carry pre-planned children in the child
/// timeline's canvas space.
/// </summary>
public sealed record FrameLayer(
    Clip Clip,
    FrameLayerKind Kind,
    int Frame,
    double SourceSeconds,
    IReadOnlyList<FrameLayer>? Children = null,
    int ChildCanvasWidth = 0,
    int ChildCanvasHeight = 0);

/// <summary>
/// Pure timeline → layer-stack planning shared by the preview compositor and export.
/// Mirrors the Mac FrameRenderer ordering: track 0 is the bottom of the stack.
/// </summary>
public static class FrameLayerPlanner
{
    private const int MaxNestingDepth = 8;

    public static List<FrameLayer> LayersAt(
        Timeline timeline, int frame,
        Func<string, Timeline?>? resolveSequence = null, int depth = 0)
    {
        var layers = new List<FrameLayer>();
        foreach (var track in timeline.Tracks)
        {
            if (track.Hidden || track.Type == ClipType.Audio) continue;
            foreach (var clip in track.Clips)
            {
                if (!clip.Contains(frame)) continue;
                if (clip.MediaType == ClipType.Audio) continue;

                if (clip.SourceClipType == ClipType.Sequence)
                {
                    if (resolveSequence is null || depth >= MaxNestingDepth) continue;
                    if (resolveSequence(clip.MediaRef) is not { } child) continue;
                    var childFrame = TimelineFrameRouter.ChildFrameFor(
                        clip, frame, timeline.Fps, child.Fps);
                    var children = LayersAt(child, childFrame, resolveSequence, depth + 1);
                    if (children.Count == 0) continue;
                    layers.Add(new FrameLayer(clip, FrameLayerKind.Group, frame, 0,
                        children, child.Width, child.Height));
                    continue;
                }

                if (clip.MediaType == ClipType.Text)
                {
                    layers.Add(new FrameLayer(clip, FrameLayerKind.Text, frame, 0));
                    continue;
                }

                layers.Add(new FrameLayer(clip, FrameLayerKind.Media, frame,
                    TimelineFrameRouter.SourceSecondsFor(clip, frame, timeline.Fps)));
            }
        }
        return layers;
    }
}
