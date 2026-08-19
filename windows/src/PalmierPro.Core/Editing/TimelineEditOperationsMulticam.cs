using PalmierPro.Core.Models;

namespace PalmierPro.Core.Editing;

/// <summary>
/// Multicam angle switching and ungrouping. Group metadata (members, sync maps) is
/// project-level state owned by the caller; these operations mutate only the timeline.
/// </summary>
public sealed partial class TimelineEditOperations
{
    public List<(int TrackIndex, Clip Clip)> MulticamClips(string groupId)
    {
        var found = new List<(int, Clip)>();
        for (var trackIndex = 0; trackIndex < Timeline.Tracks.Count; trackIndex++)
        {
            foreach (var clip in Timeline.Tracks[trackIndex].Clips)
            {
                if (clip.MulticamGroupId == groupId) found.Add((trackIndex, clip));
            }
        }
        return found;
    }

    /// <summary>The track carrying the group's program (video) cut, or null.</summary>
    public int? MulticamProgramTrack(string groupId)
    {
        int? program = null;
        foreach (var (trackIndex, clip) in MulticamClips(groupId))
        {
            if (Timeline.Tracks[trackIndex].Type != ClipType.Video || clip.MediaType == ClipType.Audio) continue;
            program = program is { } p ? Math.Max(p, trackIndex) : trackIndex;
        }
        return program;
    }

    /// <summary>
    /// Rewrites one multicam segment in place to a different member: same timeline
    /// position, source window re-anchored via the members' sync offsets.
    /// </summary>
    public bool SwitchMulticamSegment(
        string clipId, string angleLabel, MulticamSource group,
        IReadOnlyDictionary<string, double> sourceDurations)
    {
        if (FindClip(clipId) is not { } found) return false;
        var clip = found.Clip;
        if (clip.MulticamGroupId != group.Id) return false;
        if (group.MemberLabeled(angleLabel) is not { } member || !member.Usable) return false;
        var wantsAudio = clip.MediaType == ClipType.Audio;
        if (wantsAudio ? !member.ProvidesAudio : !member.ProvidesVideo) return false;
        if (clip.MediaRef == member.MediaRef) return false;

        MutateWithTimelineSwap(wantsAudio ? "Switch Mic" : "Switch Angle",
            () => Rewrite(clip, group, member, sourceDurations, Timeline.Fps));
        return true;
    }

    /// <summary>
    /// Switches the program cut to one angle across a frame range: splits straddling
    /// group segments at the range edges, then rewrites every covered segment.
    /// </summary>
    public bool SwitchMulticamRange(
        MulticamSource group, int rangeStart, int rangeEnd, string angleLabel,
        IReadOnlyDictionary<string, double> sourceDurations)
    {
        if (rangeEnd <= rangeStart) return false;
        if (group.MemberLabeled(angleLabel) is not { } member
            || !member.Usable || !member.ProvidesVideo) return false;
        if (MulticamProgramTrack(group.Id) is not { } programTrack) return false;

        var wouldChange = Timeline.Tracks[programTrack].Clips.Any(c =>
            c.MulticamGroupId == group.Id && c.MediaRef != member.MediaRef
            && c.StartFrame < rangeEnd && c.EndFrame > rangeStart);
        if (!wouldChange) return false;

        MutateWithTimelineSwap("Switch Angle", () =>
        {
            var track = Timeline.Tracks[programTrack];
            SplitGroupClipsAt(track, group.Id, rangeStart);
            SplitGroupClipsAt(track, group.Id, rangeEnd);
            foreach (var clip in track.Clips)
            {
                if (clip.MulticamGroupId != group.Id) continue;
                if (clip.StartFrame < rangeStart || clip.EndFrame > rangeEnd) continue;
                Rewrite(clip, group, member, sourceDurations, Timeline.Fps);
            }
            JoinThroughEdits(track, group.Id);
        });
        return true;
    }

    /// <summary>Detaches every clip of the group on this timeline into ordinary clips.</summary>
    public bool UngroupMulticam(string groupId)
    {
        var members = MulticamClips(groupId);
        if (members.Count == 0) return false;
        MutateWithTimelineSwap("Ungroup Multicam", () =>
        {
            foreach (var (_, clip) in members) clip.MulticamGroupId = null;
        });
        return true;
    }

    private static void Rewrite(
        Clip clip, MulticamSource group, MulticamSource.Member member,
        IReadOnlyDictionary<string, double> sourceDurations, int fps)
    {
        if (clip.MediaRef == member.MediaRef) return;
        if (group.MemberFor(clip.MediaRef) is not { } current) return;
        var delta = (int)Math.Round(
            (current.Sync.OffsetSeconds - member.Sync.OffsetSeconds) * Math.Max(1, fps),
            MidpointRounding.AwayFromZero);
        clip.MediaRef = member.MediaRef;
        clip.TrimStartFrame += delta;
        if (sourceDurations.TryGetValue(member.MediaRef, out var duration))
        {
            var sourceLength = (int)Math.Round(duration * Math.Max(1, fps), MidpointRounding.AwayFromZero);
            clip.TrimEndFrame = Math.Max(0, sourceLength - clip.TrimStartFrame - clip.SourceFramesConsumed);
        }
        else
        {
            clip.TrimEndFrame = 0;
        }
    }

    private static void SplitGroupClipsAt(Track track, string groupId, int frame)
    {
        var index = track.Clips.FindIndex(c =>
            c.MulticamGroupId == groupId && frame > c.StartFrame && frame < c.EndFrame);
        if (index < 0) return;
        var right = SplitValues(track.Clips[index], frame);
        track.Clips.Insert(index + 1, right);
    }

    /// <summary>Merges adjacent same-angle segments that form a seamless through edit.</summary>
    private static void JoinThroughEdits(Track track, string groupId)
    {
        track.Clips.Sort((a, b) => a.StartFrame.CompareTo(b.StartFrame));
        var i = 0;
        while (i + 1 < track.Clips.Count)
        {
            var left = track.Clips[i];
            var right = track.Clips[i + 1];
            if (left.MulticamGroupId == groupId && IsThroughEdit(left, right))
            {
                left.SetDuration(left.DurationFrames + right.DurationFrames);
                left.TrimEndFrame = right.TrimEndFrame;
                track.Clips.RemoveAt(i + 1);
            }
            else
            {
                i++;
            }
        }
    }

    private static bool IsThroughEdit(Clip a, Clip b)
        => a.MediaRef == b.MediaRef
            && a.MediaType == b.MediaType
            && a.MulticamGroupId == b.MulticamGroupId
            && b.StartFrame == a.EndFrame
            && b.TrimStartFrame == a.TrimStartFrame + a.SourceFramesConsumed
            && a.Speed == b.Speed
            && a.Volume == b.Volume
            && a.Opacity == b.Opacity
            && a.FadeOutFrames == 0 && b.FadeInFrames == 0
            && !a.HasKeyframes && !b.HasKeyframes;
}
