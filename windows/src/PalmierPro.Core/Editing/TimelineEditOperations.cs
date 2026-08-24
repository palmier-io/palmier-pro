using PalmierPro.Core.Models;
using PalmierPro.Core.Serialization;
using PalmierPro.Core.Undo;

namespace PalmierPro.Core.Editing;

public enum TrimEdge
{
    Left,
    Right,
}

/// <summary>
/// Domain mutation operations shared by the timeline UI and Agent tools, ported from
/// the Mac EditorViewModel mutation extensions. Every operation validates before
/// opening an undo group, mutates atomically, and produces one undoable action.
/// Overlaps are resolved by overwriting (OverwriteEngine); linked clips share timing.
/// </summary>
public sealed partial class TimelineEditOperations(Timeline timeline, EditorUndo undo)
{
    public Timeline Timeline { get; } = timeline;

    /// <summary>Raised after any successful mutation (including undo/redo) so owners can save and rebuild playback.</summary>
    public event Action? TimelineChanged;

    // MARK: - Lookup and link groups

    public (int TrackIndex, Clip Clip)? FindClip(string clipId)
    {
        for (var trackIndex = 0; trackIndex < Timeline.Tracks.Count; trackIndex++)
        {
            var clip = Timeline.Tracks[trackIndex].Clips.FirstOrDefault(c => c.Id == clipId);
            if (clip is not null) return (trackIndex, clip);
        }
        return null;
    }

    private IEnumerable<Clip> AllClips() => Timeline.Tracks.SelectMany(t => t.Clips);

    /// <summary>Expands clip ids to include every member of any touched link group.</summary>
    public HashSet<string> ExpandToLinkGroup(IEnumerable<string> clipIds)
    {
        var expanded = new HashSet<string>(clipIds);
        var groups = AllClips()
            .Where(c => expanded.Contains(c.Id) && c.LinkGroupId is not null)
            .Select(c => c.LinkGroupId!)
            .ToHashSet();
        foreach (var clip in AllClips())
        {
            if (clip.LinkGroupId is { } group && groups.Contains(group)) expanded.Add(clip.Id);
        }
        return expanded;
    }

    public List<string> LinkedPartnerIds(string clipId)
    {
        if (FindClip(clipId) is not { Clip.LinkGroupId: { } group }) return [];
        return AllClips().Where(c => c.Id != clipId && c.LinkGroupId == group).Select(c => c.Id).ToList();
    }

    /// <summary>Partner moves preserving relative offsets: same start-frame delta, floored at 0.</summary>
    public List<(string ClipId, int ToFrame)> PartnerMoves(string clipId, int toFrame)
    {
        if (FindClip(clipId) is not { } found) return [];
        var delta = toFrame - found.Clip.StartFrame;
        if (delta == 0) return [];
        return LinkedPartnerIds(clipId)
            .Select(partnerId => FindClip(partnerId))
            .Where(p => p is not null)
            .Select(p => (p!.Value.Clip.Id, Math.Max(0, p.Value.Clip.StartFrame + delta)))
            .ToList();
    }

    public bool LinkClips(IReadOnlyCollection<string> clipIds)
    {
        var clips = AllClips().Where(c => clipIds.Contains(c.Id)).ToList();
        if (clips.Count < 2) return false;
        var groupId = Uuid.NewString();
        MutateWithTimelineSwap("Link", () =>
        {
            foreach (var clip in clips) clip.LinkGroupId = groupId;
        });
        return true;
    }

    public bool UnlinkClips(IReadOnlyCollection<string> clipIds)
    {
        var groups = AllClips()
            .Where(c => clipIds.Contains(c.Id) && c.LinkGroupId is not null)
            .Select(c => c.LinkGroupId!)
            .ToHashSet();
        if (groups.Count == 0) return false;
        var members = AllClips().Where(c => c.LinkGroupId is { } g && groups.Contains(g)).ToList();
        MutateWithTimelineSwap("Unlink", () =>
        {
            foreach (var clip in members) clip.LinkGroupId = null;
        });
        return true;
    }

    // MARK: - Region clearing (overwrite)

    /// <summary>Overwrite-clears [start, end) on a track. Call only inside an open mutation.</summary>
    private void ClearRegion(int trackIndex, int start, int end, IReadOnlySet<string>? excluding = null)
    {
        if (trackIndex < 0 || trackIndex >= Timeline.Tracks.Count) return;
        var track = Timeline.Tracks[trackIndex];
        var actions = OverwriteEngine.ClearActions(track.Clips, start, end, excluding);
        OverwriteEngine.Apply(track, actions);
    }

    // MARK: - Move

    /// <summary>
    /// Batch move with overwrite semantics: movers leave their tracks, destinations are
    /// cleared, then movers land sorted. Incompatible track-type moves are dropped.
    /// </summary>
    public bool MoveClips(IReadOnlyList<(string ClipId, int ToTrack, int ToFrame)> moves)
    {
        var valid = new List<(Clip Clip, int FromTrack, int ToTrack, int ToFrame)>();
        foreach (var (clipId, toTrack, toFrame) in moves)
        {
            if (toTrack < 0 || toTrack >= Timeline.Tracks.Count) continue;
            if (FindClip(clipId) is not { } found) continue;
            if (!found.Clip.MediaType.IsCompatible(Timeline.Tracks[toTrack].Type)) continue;
            valid.Add((found.Clip, found.TrackIndex, toTrack, Math.Max(0, toFrame)));
        }
        if (valid.Count == 0) return false;
        if (valid.All(m => m.FromTrack == m.ToTrack && m.Clip.StartFrame == m.ToFrame)) return false;
        if (MulticamMoveViolation(valid)) return false;

        var moverIds = valid.Select(m => m.Clip.Id).ToHashSet();
        MutateWithTimelineSwap(valid.Count == 1 ? "Move Clip" : "Move Clips", () =>
        {
            foreach (var (clip, fromTrack, _, _) in valid)
                Timeline.Tracks[fromTrack].Clips.Remove(clip);
            foreach (var (clip, _, toTrack, toFrame) in valid)
            {
                ClearRegion(toTrack, toFrame, toFrame + clip.DurationFrames, moverIds);
                clip.StartFrame = toFrame;
                Timeline.Tracks[toTrack].Clips.Add(clip);
            }
            SortAllTracks();
            PruneEmptyTracks();
        });
        return true;
    }

    /// <summary>
    /// Multicam clips keep the group in sync: no camera-clip lane changes, and a
    /// horizontal move must carry every clip of the group.
    /// </summary>
    private bool MulticamMoveViolation(
        IReadOnlyList<(Clip Clip, int FromTrack, int ToTrack, int ToFrame)> moves)
    {
        var moverIds = moves.Select(m => m.Clip.Id).ToHashSet();
        var horizontal = moves.Any(m => m.Clip.StartFrame != m.ToFrame);
        var laneChange = moves.Any(m =>
            m.Clip.MulticamGroupId is not null
            && m.Clip.MediaType != ClipType.Audio
            && m.FromTrack != m.ToTrack);
        if (!horizontal && !laneChange) return false;
        if (laneChange) return true;
        foreach (var groupId in moves.Select(m => m.Clip.MulticamGroupId).OfType<string>().Distinct())
        {
            if (MulticamClips(groupId).Any(member => !moverIds.Contains(member.Clip.Id)))
                return true;
        }
        return false;
    }

    /// <summary>Single-clip move; linked partners follow with the same delta on their tracks.</summary>
    public bool MoveClip(string clipId, int newStartFrame)
    {
        if (newStartFrame < 0) return false;
        if (FindClip(clipId) is not { } found) return false;
        var moves = new List<(string, int, int)> { (clipId, found.TrackIndex, newStartFrame) };
        foreach (var (partnerId, toFrame) in PartnerMoves(clipId, newStartFrame))
        {
            if (FindClip(partnerId) is { } partner)
                moves.Add((partnerId, partner.TrackIndex, toFrame));
        }
        return MoveClips(moves);
    }

    // MARK: - Trim and slip

    /// <summary>
    /// Trims a clip to a new start/duration. The caller supplies the matching trimStart
    /// so source alignment is preserved (left trims shift it, right trims do not).
    /// Expansion overwrites neighbors in the affected region.
    /// </summary>
    public bool TrimClip(string clipId, int newStartFrame, int newDurationFrames, int newTrimStartFrame)
    {
        if (newStartFrame < 0 || newDurationFrames < 1 || newTrimStartFrame < 0) return false;
        if (FindClip(clipId) is not { } found) return false;
        var clip = found.Clip;
        if ((clip.StartFrame, clip.DurationFrames, clip.TrimStartFrame)
            == (newStartFrame, newDurationFrames, newTrimStartFrame))
        {
            return false;
        }

        MutateWithTimelineSwap("Trim Clip", () =>
        {
            ClearRegion(found.TrackIndex, newStartFrame, newStartFrame + newDurationFrames,
                new HashSet<string> { clip.Id });
            var deltaEndTimeline = (clip.StartFrame + clip.DurationFrames)
                - (newStartFrame + newDurationFrames);
            clip.TrimEndFrame = Math.Max(0, clip.TrimEndFrame
                + (int)Math.Round(deltaEndTimeline * clip.Speed, MidpointRounding.AwayFromZero));
            clip.StartFrame = newStartFrame;
            clip.TrimStartFrame = newTrimStartFrame;
            clip.SetDuration(newDurationFrames);
            SortAllTracks();
        });
        return true;
    }

    /// <summary>
    /// Slips the source window without moving the clip on the timeline. Delta is in
    /// timeline frames; image, text, and multicam clips are ineligible.
    /// </summary>
    public bool SlipClip(string clipId, int deltaFrames, bool propagateToLinked = true)
    {
        if (deltaFrames == 0) return false;
        if (FindClip(clipId) is not { } found) return false;
        var lead = found.Clip;
        if (!IsSlipEligible(lead)) return false;

        var group = new List<Clip> { lead };
        if (propagateToLinked)
        {
            group.AddRange(LinkedPartnerIds(clipId)
                .Select(id => FindClip(id)?.Clip)
                .Where(c => c is not null && IsSlipEligible(c))
                .Select(c => c!));
        }

        // Shared timeline delta clamped by the tightest source headroom in the group.
        var applied = deltaFrames;
        foreach (var clip in group)
        {
            var sourceDelta = (int)Math.Round(applied * clip.Speed, MidpointRounding.AwayFromZero);
            var clampedSource = Math.Clamp(sourceDelta, -clip.TrimEndFrame, clip.TrimStartFrame);
            var clampedTimeline = (int)Math.Round(clampedSource / clip.Speed, MidpointRounding.AwayFromZero);
            applied = Math.Abs(clampedTimeline) < Math.Abs(applied) ? clampedTimeline : applied;
        }
        if (applied == 0) return false;

        MutateWithTimelineSwap(group.Count == 1 ? "Slip Clip" : "Slip Clips", () =>
        {
            foreach (var clip in group)
            {
                var sourceDelta = Math.Clamp(
                    (int)Math.Round(applied * clip.Speed, MidpointRounding.AwayFromZero),
                    -clip.TrimEndFrame, clip.TrimStartFrame);
                clip.TrimStartFrame -= sourceDelta;
                clip.TrimEndFrame += sourceDelta;
            }
        });
        return true;
    }

    private static bool IsSlipEligible(Clip clip)
        => clip.MediaType is not (ClipType.Image or ClipType.Text) && clip.MulticamGroupId is null;

    // MARK: - Ripple trim

    /// <summary>
    /// Ripple-trims one edge by a signed frame delta (positive = edge moves right).
    /// The clip's start stays fixed; downstream clips on the clip's track and on
    /// sync-locked tracks shift by the end-edge movement so no gap opens or closes
    /// incorrectly. Refuses when a shift would overlap or push a clip before 0.
    /// </summary>
    public bool RippleTrimClip(string clipId, TrimEdge edge, int deltaFrames)
    {
        if (deltaFrames == 0) return false;
        if (FindClip(clipId) is not { } found) return false;
        var clip = found.Clip;

        // Left edge moving right shrinks; right edge moving right grows.
        var durationDelta = edge == TrimEdge.Left ? -deltaFrames : deltaFrames;
        var newDuration = clip.DurationFrames + durationDelta;
        if (newDuration < 1) return false;

        var sourceDelta = (int)Math.Round(deltaFrames * clip.Speed, MidpointRounding.AwayFromZero);
        var unboundedSource = clip.MediaType is ClipType.Image or ClipType.Text;
        int newTrimStart = clip.TrimStartFrame, newTrimEnd = clip.TrimEndFrame;
        if (edge == TrimEdge.Left)
        {
            newTrimStart += sourceDelta;
            if (!unboundedSource && newTrimStart < 0) return false;
            newTrimStart = Math.Max(0, newTrimStart);
        }
        else
        {
            newTrimEnd -= sourceDelta;
            if (!unboundedSource && newTrimEnd < 0) return false;
            newTrimEnd = Math.Max(0, newTrimEnd);
        }

        // Downstream shift equals the end-edge movement.
        var shiftDelta = durationDelta;
        var oldEnd = clip.EndFrame;
        if (!RippleTrimShiftIsSafe(found.TrackIndex, clip.Id, oldEnd, newDuration, shiftDelta))
            return false;

        MutateWithTimelineSwap("Ripple Trim", () =>
        {
            clip.TrimStartFrame = newTrimStart;
            clip.TrimEndFrame = newTrimEnd;
            clip.SetDuration(newDuration);
            ApplyDownstreamShift(found.TrackIndex, clip.Id, oldEnd, shiftDelta);
            SortAllTracks();
        });
        return true;
    }

    private void ApplyDownstreamShift(int editedTrackIndex, string editedClipId, int fromFrame, int delta)
    {
        for (var trackIndex = 0; trackIndex < Timeline.Tracks.Count; trackIndex++)
        {
            var track = Timeline.Tracks[trackIndex];
            if (trackIndex != editedTrackIndex && !track.SyncLocked) continue;
            foreach (var other in track.Clips)
            {
                if (other.Id == editedClipId) continue;
                if (other.StartFrame >= fromFrame) other.StartFrame += delta;
            }
        }
    }

    private bool RippleTrimShiftIsSafe(
        int editedTrackIndex, string editedClipId, int fromFrame, int newDuration, int delta)
    {
        var scratch = Clone(Timeline);
        var edited = scratch.Tracks[editedTrackIndex].Clips.First(c => c.Id == editedClipId);
        edited.DurationFrames = newDuration;
        for (var trackIndex = 0; trackIndex < scratch.Tracks.Count; trackIndex++)
        {
            var track = scratch.Tracks[trackIndex];
            if (trackIndex != editedTrackIndex && !track.SyncLocked) continue;
            foreach (var other in track.Clips)
            {
                if (other.Id == editedClipId) continue;
                if (other.StartFrame >= fromFrame)
                {
                    other.StartFrame += delta;
                    if (other.StartFrame < 0) return false;
                }
            }
            track.Clips.Sort((a, b) => a.StartFrame.CompareTo(b.StartFrame));
            if (HasOverlap(track)) return false;
        }
        return true;
    }

    // MARK: - Split

    /// <summary>
    /// Splits a clip at a timeline frame strictly inside it. Linked members split too;
    /// right halves share a fresh link group. Returns new right-half clip ids.
    /// </summary>
    public List<string> SplitClip(string clipId, int frame)
    {
        if (FindClip(clipId) is not { } found) return [];
        var members = new List<(int TrackIndex, Clip Clip)> { found };
        if (found.Clip.LinkGroupId is not null)
        {
            members.AddRange(LinkedPartnerIds(clipId)
                .Select(id => FindClip(id))
                .Where(p => p is not null)
                .Select(p => p!.Value));
        }
        var splittable = members
            .Where(m => frame > m.Clip.StartFrame && frame < m.Clip.EndFrame)
            .ToList();
        if (splittable.Count == 0) return [];

        var rightIds = new List<string>();
        var newGroupId = splittable.Count > 1 ? Uuid.NewString() : null;
        MutateWithTimelineSwap(splittable.Count == 1 ? "Split Clip" : "Split Clips", () =>
        {
            foreach (var (trackIndex, clip) in splittable)
            {
                var right = SplitValues(clip, frame);
                if (newGroupId is not null) right.LinkGroupId = newGroupId;
                var track = Timeline.Tracks[trackIndex];
                track.Clips.Insert(track.Clips.IndexOf(clip) + 1, right);
                rightIds.Add(right.Id);
            }
        });
        return rightIds;
    }

    /// <summary>Splits every selected clip intersected by the playhead.</summary>
    public List<string> SplitClipsAt(int frame, IReadOnlyCollection<string> clipIds)
    {
        var results = new List<string>();
        var processed = new HashSet<string>();
        foreach (var clipId in clipIds)
        {
            if (processed.Contains(clipId)) continue;
            foreach (var id in ExpandToLinkGroup([clipId])) processed.Add(id);
            results.AddRange(SplitClip(clipId, frame));
        }
        return results;
    }

    /// <summary>Mutates the left clip in place and returns the new right clip (not inserted).</summary>
    private static Clip SplitValues(Clip clip, int frame) // shared with RippleInsert split path
    {
        var splitOffset = frame - clip.StartFrame;
        var leftSource = (int)Math.Round(splitOffset * clip.Speed, MidpointRounding.AwayFromZero);
        var rightSource = (int)Math.Round(
            (clip.DurationFrames - splitOffset) * clip.Speed, MidpointRounding.AwayFromZero);

        var right = Clone(clip);
        right.Id = Uuid.NewString();
        right.StartFrame = frame;
        right.DurationFrames = clip.DurationFrames - splitOffset;
        right.TrimStartFrame = clip.TrimStartFrame + leftSource;
        right.FadeInFrames = 0;
        right.ClampFadesToDuration();
        RebaseKeyframes(right, splitOffset);

        clip.DurationFrames = splitOffset;
        clip.TrimEndFrame += rightSource;
        clip.FadeOutFrames = 0;
        clip.ClampFadesToDuration();
        clip.ClampKeyframesToDuration();
        return right;
    }

    private static void RebaseKeyframes(Clip clip, int offset)
    {
        clip.OpacityTrack = clip.OpacityTrack?.Rebased(offset, 1.0);
        clip.PositionTrack = clip.PositionTrack?.Rebased(offset, new AnimPair(0, 0));
        clip.ScaleTrack = clip.ScaleTrack?.Rebased(offset, new AnimPair(1, 1));
        clip.RotationTrack = clip.RotationTrack?.Rebased(offset, 0.0);
        clip.CropTrack = clip.CropTrack?.Rebased(offset, new Crop());
        clip.VolumeTrack = clip.VolumeTrack?.Rebased(offset, 0.0);
        clip.ClampKeyframesToDuration();
    }

    // MARK: - Delete

    /// <summary>Deletes the clips (and linked A/V partners), leaving gaps. Returns removed count.</summary>
    public int DeleteClips(IReadOnlyCollection<string> clipIds)
    {
        var doomed = ExpandToLinkGroup(clipIds);
        if (doomed.Count == 0) return 0;
        // Only count IDs that still exist on the timeline.
        doomed.IntersectWith(AllClips().Select(c => c.Id));
        if (doomed.Count == 0) return 0;

        MutateWithTimelineSwap(doomed.Count == 1 ? "Delete Clip" : "Delete Clips", () =>
        {
            foreach (var track in Timeline.Tracks)
                track.Clips.RemoveAll(c => doomed.Contains(c.Id));
        });
        return doomed.Count;
    }

    // MARK: - Ripple

    /// <summary>
    /// Removes clips and closes the gaps: affected tracks shift their own removals;
    /// sync-locked tracks without removals shift by the global removed ranges.
    /// Refuses when a shift would overlap or push a clip before frame 0.
    /// </summary>
    public bool RippleDeleteClips(IReadOnlyCollection<string> clipIds)
    {
        var expanded = ExpandToLinkGroup(clipIds);
        var removalsByTrack = new Dictionary<int, List<FrameRange>>();
        for (var trackIndex = 0; trackIndex < Timeline.Tracks.Count; trackIndex++)
        {
            var ranges = Timeline.Tracks[trackIndex].Clips
                .Where(c => expanded.Contains(c.Id))
                .Select(c => new FrameRange(c.StartFrame, c.EndFrame))
                .ToList();
            if (ranges.Count > 0) removalsByTrack[trackIndex] = ranges;
        }
        if (removalsByTrack.Count == 0) return false;

        var globalRanges = removalsByTrack.Values.SelectMany(r => r).ToList();
        return ApplyRippleRemoval(expanded, removalsByTrack, globalRanges, "Ripple Delete");
    }

    /// <summary>Overwrite-clears ranges on one track, then closes the gaps (ripple).</summary>
    public bool RippleDeleteRangesOnTrack(int trackIndex, IReadOnlyList<FrameRange> ranges)
    {
        if (trackIndex < 0 || trackIndex >= Timeline.Tracks.Count) return false;
        var merged = RippleEngine.MergeRanges(ranges);
        if (merged.Count == 0) return false;

        if (!RippleShiftsAreSafe(trackIndex, merged, merged)) return false;

        MutateWithTimelineSwap("Ripple Delete", () =>
        {
            foreach (var range in merged) ClearRegion(trackIndex, range.Start, range.End);
            ApplyShiftsForRanges(merged, ownRangesByTrack: new() { [trackIndex] = merged });
        });
        return true;
    }

    /// <summary>Closes an empty gap on a track (the gap must contain no clips).</summary>
    public bool RippleDeleteGap(int trackIndex, FrameRange gap)
    {
        if (trackIndex < 0 || trackIndex >= Timeline.Tracks.Count || !gap.IsValid) return false;
        var track = Timeline.Tracks[trackIndex];
        if (track.Clips.Any(c => c.StartFrame < gap.End && c.EndFrame > gap.Start)) return false;
        var ranges = new List<FrameRange> { gap };
        if (!RippleShiftsAreSafe(trackIndex, ranges, ranges)) return false;

        MutateWithTimelineSwap("Ripple Delete", () =>
            ApplyShiftsForRanges(ranges, ownRangesByTrack: new() { [trackIndex] = ranges }));
        return true;
    }

    private bool ApplyRippleRemoval(
        HashSet<string> removedIds,
        Dictionary<int, List<FrameRange>> removalsByTrack,
        List<FrameRange> globalRanges,
        string actionName)
    {
        // Validate on a scratch copy first: sync-locked shifts must not overlap or go negative.
        var scratch = Clone(Timeline);
        foreach (var track in scratch.Tracks) track.Clips.RemoveAll(c => removedIds.Contains(c.Id));
        for (var trackIndex = 0; trackIndex < scratch.Tracks.Count; trackIndex++)
        {
            var track = scratch.Tracks[trackIndex];
            var ranges = removalsByTrack.GetValueOrDefault(trackIndex)
                ?? (track.SyncLocked ? RippleEngine.MergeRanges(globalRanges) : []);
            if (ranges.Count == 0) continue;
            foreach (var shift in RippleEngine.ComputeRippleShiftsForRanges(track.Clips, ranges))
            {
                if (shift.NewStartFrame < 0) return false;
                var clip = track.Clips.First(c => c.Id == shift.ClipId);
                clip.StartFrame = shift.NewStartFrame;
            }
            track.Clips.Sort((a, b) => a.StartFrame.CompareTo(b.StartFrame));
            if (HasOverlap(track)) return false;
        }

        MutateWithTimelineSwap(actionName, () =>
        {
            foreach (var track in Timeline.Tracks) track.Clips.RemoveAll(c => removedIds.Contains(c.Id));
            ApplyShiftsForRanges(globalRanges, removalsByTrack);
        });
        return true;
    }

    private void ApplyShiftsForRanges(
        List<FrameRange> globalRanges, Dictionary<int, List<FrameRange>> ownRangesByTrack)
    {
        for (var trackIndex = 0; trackIndex < Timeline.Tracks.Count; trackIndex++)
        {
            var track = Timeline.Tracks[trackIndex];
            var ranges = ownRangesByTrack.GetValueOrDefault(trackIndex)
                ?? (track.SyncLocked ? RippleEngine.MergeRanges(globalRanges) : []);
            if (ranges.Count == 0) continue;
            foreach (var shift in RippleEngine.ComputeRippleShiftsForRanges(track.Clips, ranges))
            {
                var clip = track.Clips.FirstOrDefault(c => c.Id == shift.ClipId);
                if (clip is not null) clip.StartFrame = Math.Max(0, shift.NewStartFrame);
            }
            track.Clips.Sort((a, b) => a.StartFrame.CompareTo(b.StartFrame));
        }
    }

    private bool RippleShiftsAreSafe(
        int trackIndex, List<FrameRange> ownRanges, List<FrameRange> globalRanges)
    {
        var scratch = Clone(Timeline);
        for (var i = 0; i < scratch.Tracks.Count; i++)
        {
            var track = scratch.Tracks[i];
            List<FrameRange> ranges;
            if (i == trackIndex)
            {
                // Own track: region will be cleared first, so simulate the clear.
                foreach (var range in ownRanges)
                {
                    var actions = OverwriteEngine.ClearActions(track.Clips, range.Start, range.End);
                    OverwriteEngine.Apply(track, actions);
                }
                ranges = ownRanges;
            }
            else
            {
                ranges = track.SyncLocked ? RippleEngine.MergeRanges(globalRanges) : [];
            }
            if (ranges.Count == 0) continue;
            foreach (var shift in RippleEngine.ComputeRippleShiftsForRanges(track.Clips, ranges))
            {
                if (shift.NewStartFrame < 0) return false;
                var clip = track.Clips.First(c => c.Id == shift.ClipId);
                clip.StartFrame = shift.NewStartFrame;
            }
            track.Clips.Sort((a, b) => a.StartFrame.CompareTo(b.StartFrame));
            if (HasOverlap(track)) return false;
        }
        return true;
    }

    private static bool HasOverlap(Track track)
    {
        for (var i = 1; i < track.Clips.Count; i++)
        {
            if (track.Clips[i].StartFrame < track.Clips[i - 1].EndFrame) return true;
        }
        return false;
    }

    // MARK: - Speed

    /// <summary>Retimed duration preserving source span: duration * speed / newSpeed, min 1.</summary>
    public static int RetimedDurationFrames(int durationFrames, double speed, double newSpeed)
        => Math.Max(1, (int)Math.Round(durationFrames * speed / newSpeed, MidpointRounding.AwayFromZero));

    /// <summary>Changes playback speed, retiming duration and rescaling keyframes and word timings.</summary>
    public bool SetClipSpeed(string clipId, double newSpeed)
    {
        if (!double.IsFinite(newSpeed) || newSpeed < 0.25 || newSpeed > 4.0) return false;
        if (FindClip(clipId) is not { } found) return false;
        var clip = found.Clip;
        if (!clip.SupportsRetiming || clip.MulticamGroupId is not null) return false;
        if (Math.Abs(clip.Speed - newSpeed) < 1e-9) return false;

        var newDuration = RetimedDurationFrames(clip.DurationFrames, clip.Speed, newSpeed);
        MutateWithTimelineSwap("Change Speed", () =>
        {
            ClearRegion(found.TrackIndex, clip.StartFrame, clip.StartFrame + newDuration,
                new HashSet<string> { clip.Id });
            var scale = (double)newDuration / Math.Max(1, clip.DurationFrames);
            clip.Speed = newSpeed;
            clip.RescaleKeyframes(scale);
            clip.SetDuration(newDuration);
            SortAllTracks();
        });
        return true;
    }

    // MARK: - Clip properties

    /// <summary>Static clip opacity in [0, 1] (visual clips only).</summary>
    public bool SetClipOpacity(string clipId, double opacity)
    {
        if (!double.IsFinite(opacity) || opacity < 0 || opacity > 1) return false;
        if (FindClip(clipId) is not { } found || !found.Clip.MediaType.IsVisual()) return false;
        var clip = found.Clip;
        if (Math.Abs(clip.Opacity - opacity) < 1e-9) return false;
        MutateWithTimelineSwap("Change Opacity", () => clip.Opacity = opacity);
        return true;
    }

    /// <summary>Clip volume in dB within [−60, +15]; −60 mutes. Propagates to linked partners.</summary>
    public bool SetClipVolumeDb(string clipId, double db, bool propagateToLinked = true)
    {
        if (!double.IsFinite(db) || db < VolumeScale.FloorDb || db > VolumeScale.CeilingDb) return false;
        if (FindClip(clipId) is not { } found) return false;
        var linear = VolumeScale.LinearFromDb(db);

        var targets = new List<Clip> { found.Clip };
        if (propagateToLinked)
        {
            targets.AddRange(LinkedPartnerIds(clipId)
                .Select(id => FindClip(id)?.Clip)
                .Where(c => c is not null && c.MediaType == ClipType.Audio)
                .Select(c => c!));
        }
        if (targets.All(c => Math.Abs(c.Volume - linear) < 1e-9)) return false;

        MutateWithTimelineSwap("Change Volume", () =>
        {
            foreach (var clip in targets) clip.Volume = linear;
        });
        return true;
    }

    /// <summary>Fade length for one edge, clamped to fit the clip's duration.</summary>
    public bool SetClipFade(string clipId, FadeEdge edge, int frames)
    {
        if (frames < 0) return false;
        if (FindClip(clipId) is not { } found) return false;
        var clip = found.Clip;
        if (clip.FadeFrames(edge) == Math.Min(frames, clip.DurationFrames)) return false;
        MutateWithTimelineSwap("Change Fade", () => clip.SetFade(edge, frames));
        return true;
    }

    // MARK: - Shared helpers

    private static Clip Clone(Clip clip)
        => PalmierJson.Decode<Clip>(PalmierJson.Encode(clip))
            ?? throw new InvalidOperationException("Clip clone round-trip failed");

    private static Timeline Clone(Timeline timeline)
        => PalmierJson.Decode<Timeline>(PalmierJson.Encode(timeline))
            ?? throw new InvalidOperationException("Timeline clone round-trip failed");

    private void SortAllTracks()
    {
        foreach (var track in Timeline.Tracks)
            track.Clips.Sort((a, b) => a.StartFrame.CompareTo(b.StartFrame));
    }

    /// <summary>
    /// Full timeline-swap undo, mirroring the Mac withTimelineSwap: snapshot before,
    /// apply, snapshot after; undo/redo swap track lists wholesale.
    /// </summary>
    private void MutateWithTimelineSwap(string actionName, Action apply)
    {
        var before = Clone(Timeline).Tracks;
        undo.Perform(actionName, () =>
        {
            apply();
            var after = Clone(Timeline).Tracks;
            RegisterTracksSwap(actionName, before, after);
        });
        TimelineChanged?.Invoke();
    }

    private void RegisterTracksSwap(string actionName, List<Track> restoreTo, List<Track> current)
    {
        undo.Register(actionName, () =>
        {
            SetTracks(restoreTo);
            // Registration during undo lands on the redo stack (and vice versa).
            RegisterTracksSwap(actionName, current, restoreTo);
            TimelineChanged?.Invoke();
        });
    }

    private void SetTracks(List<Track> tracks)
    {
        Timeline.Tracks.Clear();
        // Deep-copy so later mutations never alias a snapshot held by the undo stack.
        foreach (var track in tracks)
        {
            var copy = PalmierJson.Decode<Track>(PalmierJson.Encode(track))
                ?? throw new InvalidOperationException("Track clone round-trip failed");
            Timeline.Tracks.Add(copy);
        }
    }
}
