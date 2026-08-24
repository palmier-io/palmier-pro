using PalmierPro.Core.Models;

namespace PalmierPro.Core.Editing;

public sealed partial class TimelineEditOperations
{
    /// <summary>Apply layout transforms/crops to existing clips by slot. Caller supplies resolved clip ids per slot.</summary>
    public bool ApplyLayoutToClips(
        VideoLayout layout,
        LayoutFit fit,
        IReadOnlyDictionary<string, IReadOnlyList<string>> clipIdsBySlot,
        Func<Clip, double?> mediaCanvasAspect)
    {
        var slots = layout.Slots();
        if (slots.Count == 0 || clipIdsBySlot.Count == 0) return false;
        var canvasAspect = Timeline.Width / (double)Math.Max(1, Timeline.Height);

        MutateWithTimelineSwap("Apply Layout", () =>
        {
            foreach (var slot in slots)
            {
                if (!clipIdsBySlot.TryGetValue(slot.Id, out var ids)) continue;
                foreach (var id in ids)
                {
                    if (FindClip(id) is not { } found) continue;
                    var clip = found.Clip;
                    if (clip.MediaType is not (ClipType.Video or ClipType.Image)) continue;
                    var (transform, crop) = LayoutMath.Placement(
                        slot.Rect, fit, mediaCanvasAspect(clip), canvasAspect);
                    clip.Transform = transform;
                    clip.Crop = crop;
                    clip.PositionTrack = null;
                    clip.ScaleTrack = null;
                    clip.RotationTrack = null;
                    clip.CropTrack = null;
                }
            }
        });
        return true;
    }

    public List<string> PlaceTextClips(IReadOnlyList<TextClipSpec> specs)
    {
        if (specs.Count == 0) return [];
        var ids = new List<string>();
        MutateWithTimelineSwap(specs.Count == 1 ? "Add Text" : "Add Texts", () =>
        {
            foreach (var spec in specs)
            {
                if (spec.TrackIndex < 0 || spec.TrackIndex >= Timeline.Tracks.Count) continue;
                var track = Timeline.Tracks[spec.TrackIndex];
                if (!ClipType.Text.IsCompatible(track.Type)) continue;
                ClearRegion(spec.TrackIndex, spec.StartFrame, spec.StartFrame + spec.DurationFrames);
                var clip = new Clip
                {
                    MediaRef = "text",
                    MediaType = ClipType.Text,
                    SourceClipType = ClipType.Text,
                    StartFrame = spec.StartFrame,
                    DurationFrames = spec.DurationFrames,
                    TextContent = spec.Content,
                    TextStyle = spec.Style,
                    Transform = spec.Transform,
                    TextAnimation = spec.Animation,
                    TextFillMode = spec.FillMode,
                };
                track.Clips.Add(clip);
                ids.Add(clip.Id);
            }
            SortAllTracks();
        });
        return ids;
    }

    public bool SetKeyframesOpacity(string clipId, KeyframeTrack<double>? track)
        => MutateKeyframe(clipId, "Set Keyframes", c => c.OpacityTrack = track);

    public bool SetKeyframesRotation(string clipId, KeyframeTrack<double>? track)
        => MutateKeyframe(clipId, "Set Keyframes", c => c.RotationTrack = track);

    public bool SetKeyframesVolumeDb(string clipId, KeyframeTrack<double>? track)
        => MutateKeyframe(clipId, "Set Keyframes", c => c.VolumeTrack = track);

    public bool SetKeyframesPosition(string clipId, KeyframeTrack<AnimPair>? track)
        => MutateKeyframe(clipId, "Set Keyframes", c => c.PositionTrack = track);

    public bool SetKeyframesScale(string clipId, KeyframeTrack<AnimPair>? track)
        => MutateKeyframe(clipId, "Set Keyframes", c => c.ScaleTrack = track);

    public bool SetKeyframesCrop(string clipId, KeyframeTrack<Crop>? track)
        => MutateKeyframe(clipId, "Set Keyframes", c => c.CropTrack = track);

    private bool MutateKeyframe(string clipId, string action, Action<Clip> apply)
    {
        if (FindClip(clipId) is not { } found) return false;
        MutateWithTimelineSwap(action, () => apply(found.Clip));
        return true;
    }
}

public readonly record struct TextClipSpec(
    int TrackIndex,
    int StartFrame,
    int DurationFrames,
    string Content,
    TextStyle Style,
    Transform Transform,
    TextAnimation? Animation = null,
    TextFillMode? FillMode = null);
