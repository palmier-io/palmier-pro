using PalmierPro.Core.Models;

namespace PalmierPro.Core.Editing;

public sealed partial class TimelineEditOperations
{
    public bool SetClipTransform(string clipId, Transform transform)
    {
        if (FindClip(clipId) is not { } found) return false;
        MutateWithTimelineSwap("Set Transform", () =>
        {
            found.Clip.Transform = transform;
            found.Clip.PositionTrack = null;
            found.Clip.ScaleTrack = null;
            found.Clip.RotationTrack = null;
        });
        return true;
    }

    public bool SetClipCrop(string clipId, Crop crop)
    {
        if (FindClip(clipId) is not { } found) return false;
        MutateWithTimelineSwap("Set Crop", () =>
        {
            found.Clip.Crop = crop;
            found.Clip.CropTrack = null;
        });
        return true;
    }

    public bool SetClipEdges(string clipId, double? rounding, double? softness)
    {
        if (FindClip(clipId) is not { } found) return false;
        if (rounding is null && softness is null) return false;
        MutateWithTimelineSwap("Set Edges", () =>
        {
            if (rounding is { } r)
                found.Clip.EdgeRounding = Math.Clamp(r, 0, 1);
            if (softness is { } s)
                found.Clip.EdgeSoftness = Math.Clamp(s, 0, 1);
        });
        return true;
    }

    public bool SetClipBlendMode(string clipId, BlendMode? mode)
    {
        if (FindClip(clipId) is not { } found) return false;
        MutateWithTimelineSwap("Set Blend Mode", () => found.Clip.BlendMode = mode);
        return true;
    }

    public bool SetClipTrimDuration(
        string clipId, int? trimStart, int? trimEnd, int? durationFrames, int? startFrame)
    {
        if (FindClip(clipId) is not { } found) return false;
        var clip = found.Clip;
        var newStart = startFrame ?? clip.StartFrame;
        var newDur = durationFrames ?? clip.DurationFrames;
        var newTrimStart = trimStart ?? clip.TrimStartFrame;
        if (newDur < 1 || newStart < 0 || newTrimStart < 0) return false;
        return TrimClip(clipId, newStart, newDur, newTrimStart)
               || ApplyTrimEndOnly(clipId, trimEnd);
    }

    private bool ApplyTrimEndOnly(string clipId, int? trimEnd)
    {
        if (trimEnd is null) return false;
        if (FindClip(clipId) is not { } found) return false;
        if (found.Clip.TrimEndFrame == trimEnd.Value) return false;
        MutateWithTimelineSwap("Set Trim End", () =>
            found.Clip.TrimEndFrame = Math.Max(0, trimEnd.Value));
        return true;
    }

    public bool ReorderTrack(int fromIndex, int toIndex)
    {
        if (fromIndex < 0 || fromIndex >= Timeline.Tracks.Count) return false;
        if (toIndex < 0 || toIndex >= Timeline.Tracks.Count) return false;
        if (fromIndex == toIndex) return false;
        var track = Timeline.Tracks[fromIndex];
        // Keep video/audio partition.
        var target = PartitionedInsertionIndex(toIndex, track.Type);
        if (target == fromIndex) return false;
        MutateWithTimelineSwap("Reorder Track", () =>
        {
            Timeline.Tracks.RemoveAt(fromIndex);
            if (target > fromIndex) target--;
            Timeline.Tracks.Insert(target, track);
        });
        return true;
    }

    public bool SetTrackFlags(int trackIndex, bool? muted, bool? hidden, bool? syncLocked)
    {
        if (trackIndex < 0 || trackIndex >= Timeline.Tracks.Count) return false;
        if (muted is null && hidden is null && syncLocked is null) return false;
        var track = Timeline.Tracks[trackIndex];
        if (syncLocked is not null && track.Clips.Any(c => c.MulticamGroupId is not null))
            return false;
        MutateWithTimelineSwap("Set Track", () =>
        {
            if (muted is { } m) track.Muted = m;
            if (hidden is { } h) track.Hidden = h;
            if (syncLocked is { } s) track.SyncLocked = s;
        });
        return true;
    }

    public bool StampCaptionGroup(IReadOnlyCollection<string> clipIds, string groupId)
    {
        var targets = clipIds
            .Select(id => FindClip(id)?.Clip)
            .Where(c => c is not null)
            .Select(c => c!)
            .ToList();
        if (targets.Count == 0) return false;
        MutateWithTimelineSwap("Stamp Caption Group", () =>
        {
            foreach (var clip in targets)
                clip.CaptionGroupId = groupId;
        });
        return true;
    }
}
