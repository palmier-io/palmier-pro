using PalmierPro.Core;
using PalmierPro.Core.Models;
using PalmierPro.Core.Timeline;

namespace PalmierPro.App.ViewModels.Editor;

/// Ripple trim result: resized clips, shifted clips, and optional obstacle frame if clamped.
public sealed record RippleTrimResize(string ClipId, int TrimStart, int TrimEnd, int Duration);

public sealed record RippleTrimPlan(int DurationDelta, IReadOnlyList<RippleTrimResize> Resizes, IReadOnlyList<ClipShift> Shifts, int? BlockedAtFrame)
{
    public HashSet<string> TargetIds => [.. Resizes.Select(r => r.ClipId)];
}

public sealed record RippleRangesReport(
    int RemovedFrames,
    int ClearedTracks,
    int ShiftedClips,
    int AnchorTrackIndex,
    IReadOnlyList<(string ClipId, int StartFrame, int DurationFrames)> ResultingFragments,
    IReadOnlyList<string> RemovedClipIds);

/// C# has no native sum type; mirrors Swift's `RippleRangesOutcome` enum as a small record
/// hierarchy, same pattern as `OverwriteAction`.
public abstract record RippleRangesOutcome
{
    public sealed record Ok(RippleRangesReport Report) : RippleRangesOutcome;

    public sealed record Refused(string Reason) : RippleRangesOutcome;
}

/// Ripple editing syncs trims, deletes, and inserts across tracks. Ports
/// `EditorViewModel+Ripple.swift`. Multicam atomicity guards (`multicamManualRippleViolation`,
/// `multicamAtomicityViolation`) are not ported — see this class's top-level doc comment.
public sealed partial class TimelineEditorViewModel
{
    // MARK: - Public API

    /// Trims clips as a batch, keeping linked clips trimmed together.
    public void TrimClips(IReadOnlyList<(string ClipId, int TrimStartFrame, int TrimEndFrame)> edits)
    {
        if (edits.Count == 0)
        {
            return;
        }
        var batchIds = new HashSet<string>(edits.Select(e => e.ClipId));
        Document.UndoService.BeginGrouping();
        foreach (var e in edits)
        {
            TrimClipInternal(e.ClipId, e.TrimStartFrame, e.TrimEndFrame, batchIds);
        }
        Document.UndoService.EndGrouping();
        Document.UndoService.SetActionName(edits.Count == 1 ? "Trim Clip" : "Trim Clips");
    }

    /// Plans a non-destructive ripple trim, capped by the strictest linked or sync-locked
    /// constraint.
    public RippleTrimPlan? PlanRippleTrim(string clipId, TrimEdge edge, int deltaFrames, bool propagateToLinked)
    {
        if (deltaFrames == 0 || FindClip(clipId) is not { } leadLoc)
        {
            return null;
        }
        var leadEnd = Timeline.Tracks[leadLoc.TrackIndex].Clips[leadLoc.ClipIndex].EndFrame;

        var targets = new List<string> { clipId };
        if (propagateToLinked)
        {
            targets.AddRange(LinkedPartnerIds(clipId));
        }
        var targetIds = new HashSet<string>(targets);
        var targetClips = targets
            .Select(id => FindClip(id) is { } l ? Timeline.Tracks[l.TrackIndex].Clips[l.ClipIndex] : null)
            .Where(c => c is not null).Select(c => c!).ToList();

        // Each target's own source headroom caps how far it can ripple; bind to the smallest.
        var sourceDelta = targetClips.Count == 0
            ? 0
            : targetClips.Select(c => RippleTrimDurationDelta(c, edge, deltaFrames)).OrderBy(d => Math.Abs(d)).First();

        // Shrinking shifts sync-locked followers left; clamp to the tightest available room.
        var durationDelta = sourceDelta;
        int? blockedAtFrame = null;
        if (sourceDelta < 0)
        {
            var limits = Timeline.Tracks
                .Where(t => t.SyncLocked && !t.Clips.Any(c => targetIds.Contains(c.Id)))
                .Select(t => SyncLockedLeftRoom(t, leadEnd))
                .Where(l => l is not null)
                .Select(l => l!.Value)
                .ToList();
            if (limits.Count > 0)
            {
                var tightest = limits.OrderBy(l => l.Room).First();
                if (sourceDelta < -tightest.Room)
                {
                    durationDelta = -tightest.Room;
                    blockedAtFrame = tightest.Obstacle;
                }
            }
        }
        if (durationDelta == 0 && blockedAtFrame is null)
        {
            return null;
        }

        // A right-edge duration change maps to the same source-frame edge drag; left flips sign.
        var resizes = targetClips.Select(c =>
        {
            var fields = TrimValues(c, edge, edge == TrimEdge.Right ? durationDelta : -durationDelta);
            return new RippleTrimResize(c.Id, fields.TrimStart, fields.TrimEnd, Math.Max(1, c.DurationFrames + durationDelta));
        }).ToList();

        var shifts = new List<ClipShift>();
        foreach (var track in Timeline.Tracks)
        {
            var targetClip = track.Clips.FirstOrDefault(c => targetIds.Contains(c.Id));
            if (targetClip is null && !track.SyncLocked)
            {
                continue;
            }
            shifts.AddRange(RippleEngine.ComputeRipplePush(track.Clips, targetClip?.EndFrame ?? leadEnd, durationDelta, targetIds));
        }
        return new RippleTrimPlan(durationDelta, resizes, shifts, blockedAtFrame);
    }

    /// Max left shift for sync-locked clips before hitting the next obstacle; null if no shift
    /// possible.
    private static (int Room, int Obstacle)? SyncLockedLeftRoom(Track track, int insertFrame)
    {
        var candidates = track.Clips.Where(c => c.StartFrame >= insertFrame).Select(c => c.StartFrame).ToList();
        if (candidates.Count == 0)
        {
            return null;
        }
        var first = candidates.Min();
        var priorEnds = track.Clips.Where(c => c.StartFrame < insertFrame).Select(c => c.EndFrame).ToList();
        var prevEnd = priorEnds.Count == 0 ? 0 : priorEnds.Max();
        return (Math.Max(0, first - prevEnd), prevEnd);
    }

    /// Ripple trim: resizes a clip from the dragged edge and shifts every clip after it.
    public void RippleTrimClip(string clipId, TrimEdge edge, int deltaFrames, bool propagateToLinked)
    {
        if (PlanRippleTrim(clipId, edge, deltaFrames, propagateToLinked) is not { } plan)
        {
            return;
        }

        var touched = new HashSet<string>(plan.TargetIds);
        foreach (var s in plan.Shifts)
        {
            touched.Add(s.ClipId);
        }

        WithTimelineSwap("Ripple Trim", true, () =>
        {
            foreach (var r in plan.Resizes)
            {
                if (FindClip(r.ClipId) is not { } l)
                {
                    continue;
                }
                var c = Timeline.Tracks[l.TrackIndex].Clips[l.ClipIndex];
                c.TrimStartFrame = r.TrimStart;
                c.TrimEndFrame = r.TrimEnd;
                c.SetDuration(r.Duration);
            }
            ApplyShifts(plan.Shifts);
            for (var ti = 0; ti < Timeline.Tracks.Count; ti++)
            {
                if (Timeline.Tracks[ti].Clips.Any(c => touched.Contains(c.Id)))
                {
                    SortClips(ti);
                }
            }
        });
    }

    /// Timeline delta from a ripple trim of `clip` by `delta` frames.
    private static int RippleTrimDurationDelta(Clip clip, TrimEdge edge, int delta)
    {
        var fields = TrimValues(clip, edge, delta);
        var sourceShift = fields.TrimStart - clip.TrimStartFrame + (fields.TrimEnd - clip.TrimEndFrame);
        return -SwiftMath.RoundToInt(sourceShift / clip.Speed);
    }

    /// Ripple delete: removes selected clips and shifts sync-locked tracks to keep them aligned.
    public void RippleDeleteSelectedClips()
    {
        var ids = SelectedClipIds;
        if (ids.Count == 0)
        {
            return;
        }

        // Merged ranges used to shift sync-locked tracks that have no deletions of their own.
        var globalRemovedRanges = Timeline.Tracks
            .SelectMany(t => t.Clips)
            .Where(c => ids.Contains(c.Id))
            .Select(c => new FrameRange(c.StartFrame, c.EndFrame))
            .ToList();

        var shiftsByTrack = new Dictionary<int, List<ClipShift>>();
        for (var ti = 0; ti < Timeline.Tracks.Count; ti++)
        {
            var track = Timeline.Tracks[ti];
            var hasOwnRemovals = track.Clips.Any(c => ids.Contains(c.Id));
            if (hasOwnRemovals)
            {
                shiftsByTrack[ti] = RippleEngine.ComputeRippleShifts(track.Clips, ids);
            }
            else if (track.SyncLocked)
            {
                var shifts = RippleEngine.ComputeRippleShiftsForRanges(track.Clips, globalRemovedRanges);
                if (ValidateShifts(ti, shifts) is { } reason)
                {
                    RefuseRipple(reason);
                    return;
                }
                shiftsByTrack[ti] = shifts;
            }
        }

        WithTimelineSwap("Ripple Delete", false, () =>
        {
            RemoveClips(ids);
            foreach (var shifts in shiftsByTrack.Values)
            {
                ApplyShifts(shifts);
            }
        });
    }

    public int ApplyShifts(IReadOnlyList<ClipShift> shifts)
    {
        var applied = 0;
        foreach (var shift in shifts)
        {
            if (FindClip(shift.ClipId) is not { } loc)
            {
                continue;
            }
            Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex].StartFrame = shift.NewStartFrame;
            applied++;
        }
        return applied;
    }

    /// Ripple-deletes timeline-frame `ranges` anchored to `anchorClipId`.
    public RippleRangesOutcome RippleDeleteRanges(string anchorClipId, IReadOnlyList<FrameRange> ranges)
    {
        if (FindClip(anchorClipId) is not { } anchorLoc)
        {
            return new RippleRangesOutcome.Refused($"Clip not found: {anchorClipId}");
        }
        return RippleDeleteRangesOnTrack(anchorLoc.TrackIndex, ranges);
    }

    /// Ripple-deletes frame ranges on a track, including linked and sync-locked tracks. Tracks in
    /// `ignoreSyncLockTrackIndices` are unlocked for this call.
    public RippleRangesOutcome RippleDeleteRangesOnTrack(int trackIndex, IReadOnlyList<FrameRange> ranges, ISet<int>? ignoreSyncLockTrackIndices = null)
    {
        ignoreSyncLockTrackIndices ??= new HashSet<int>();
        if (trackIndex < 0 || trackIndex >= Timeline.Tracks.Count)
        {
            return new RippleRangesOutcome.Refused($"Track index out of range: {trackIndex}");
        }
        var ignoredTrackIds = new HashSet<string>(
            ignoreSyncLockTrackIndices.Where(i => i >= 0 && i < Timeline.Tracks.Count).Select(i => Timeline.Tracks[i].Id));
        var merged = RippleEngine.MergeRanges([.. ranges.Where(r => r.Length > 0)]);
        if (merged.Count == 0)
        {
            return new RippleRangesOutcome.Refused("No non-empty ranges to delete");
        }
        var totalRemoved = merged.Sum(r => r.Length);

        var anchorTrackId = Timeline.Tracks[trackIndex].Id;
        var clearTrackIds = new HashSet<string> { anchorTrackId };
        foreach (var track in Timeline.Tracks.Where(t => t.SyncLocked && !ignoredTrackIds.Contains(t.Id)))
        {
            clearTrackIds.Add(track.Id);
        }

        // Ensure all linked partners of affected clips are included to keep A/V in sync.
        var frontier = new HashSet<string>(clearTrackIds);
        while (frontier.Count > 0)
        {
            var added = new HashSet<string>();
            foreach (var tid in frontier)
            {
                var ti = Timeline.Tracks.FindIndex(t => t.Id == tid);
                if (ti < 0)
                {
                    continue;
                }
                foreach (var clip in Timeline.Tracks[ti].Clips)
                {
                    if (clip.LinkGroupId is null)
                    {
                        continue;
                    }
                    if (!merged.Any(r => r.Start < clip.EndFrame && r.End > clip.StartFrame))
                    {
                        continue;
                    }
                    foreach (var pid in LinkedPartnerIds(clip.Id))
                    {
                        if (FindClip(pid) is not { } l)
                        {
                            continue;
                        }
                        var partnerTid = Timeline.Tracks[l.TrackIndex].Id;
                        if (clearTrackIds.Add(partnerTid))
                        {
                            added.Add(partnerTid);
                        }
                    }
                }
            }
            frontier = added;
        }

        // Refuse up front if a sync-locked follower can't absorb the shift after clearing.
        for (var ti = 0; ti < Timeline.Tracks.Count; ti++)
        {
            var track = Timeline.Tracks[ti];
            if (clearTrackIds.Contains(track.Id) || !track.SyncLocked || ignoredTrackIds.Contains(track.Id))
            {
                continue;
            }
            var shifts = RippleEngine.ComputeRippleShiftsForRanges(track.Clips, merged);
            if (ValidateShifts(ti, shifts) is { } reason)
            {
                return new RippleRangesOutcome.Refused(reason);
            }
        }

        var anchorBeforeIds = new HashSet<string>(Timeline.Tracks[trackIndex].Clips.Select(c => c.Id));

        var shiftedClips = 0;
        WithTimelineSwap("Ripple Delete", true, () =>
        {
            foreach (var tid in clearTrackIds)
            {
                var ti = Timeline.Tracks.FindIndex(t => t.Id == tid);
                if (ti < 0)
                {
                    continue;
                }
                foreach (var r in merged)
                {
                    ClearRegion(ti, r.Start, r.End, prune: false);
                }
            }
            for (var ti = 0; ti < Timeline.Tracks.Count; ti++)
            {
                var track = Timeline.Tracks[ti];
                if (!(clearTrackIds.Contains(track.Id) || (track.SyncLocked && !ignoredTrackIds.Contains(track.Id))))
                {
                    continue;
                }
                var shifts = RippleEngine.ComputeRippleShiftsForRanges(track.Clips, merged);
                shiftedClips += ApplyShifts(shifts);
                SortClips(ti);
            }
        });

        // Anchor track's post-cut layout (surviving + new fragments) so the caller needn't re-read.
        var anchorTi = Timeline.Tracks.FindIndex(t => t.Id == anchorTrackId);
        if (anchorTi < 0)
        {
            anchorTi = trackIndex;
        }
        var afterClips = Timeline.Tracks[anchorTi].Clips;
        var afterIds = new HashSet<string>(afterClips.Select(c => c.Id));
        // Source note: the Swift filter here (`afterIds.subtracting(anchorBeforeIds).contains($0.id)
        // || anchorBeforeIds.contains($0.id)`) is a tautology over `afterClips` — every clip in
        // `afterClips` is, by construction, either newly created (so in the subtraction set) or a
        // survivor (so in `anchorBeforeIds`). Omitted here; `afterClips` alone is equivalent.
        var fragments = afterClips
            .OrderBy(c => c.StartFrame)
            .Select(c => (c.Id, c.StartFrame, c.DurationFrames))
            .ToList();
        return new RippleRangesOutcome.Ok(new RippleRangesReport(
            totalRemoved, clearTrackIds.Count, shiftedClips, anchorTi, fragments,
            [.. anchorBeforeIds.Except(afterIds)]));
    }

    public void RippleDeleteSelectedGap()
    {
        if (SelectedGap is not { } gap)
        {
            return;
        }
        if (gap.TrackIndex < 0 || gap.TrackIndex >= Timeline.Tracks.Count || gap.Range.Length <= 0)
        {
            return;
        }
        // An out-of-band edit may have filled the gap.
        if (Timeline.Tracks[gap.TrackIndex].Clips.Any(c => c.StartFrame < gap.Range.End && c.EndFrame > gap.Range.Start))
        {
            SelectedGap = null;
            return;
        }

        var shiftsByTrack = new Dictionary<int, List<ClipShift>>();
        for (var ti = 0; ti < Timeline.Tracks.Count; ti++)
        {
            if (ti != gap.TrackIndex && !Timeline.Tracks[ti].SyncLocked)
            {
                continue;
            }
            var shifts = RippleEngine.ComputeRippleShiftsForRanges(Timeline.Tracks[ti].Clips, [gap.Range]);
            // The gap track only ever moves clips into freed space; sync-locked followers may collide.
            if (ti != gap.TrackIndex && ValidateShifts(ti, shifts) is { } reason)
            {
                RefuseRipple(reason);
                return;
            }
            shiftsByTrack[ti] = shifts;
        }

        WithTimelineSwap("Ripple Delete", true, () =>
        {
            foreach (var shifts in shiftsByTrack.Values)
            {
                ApplyShifts(shifts);
            }
        });
        SelectedGap = null;
    }

    /// Ripple insert: adds clips at `atFrame` and pushes everything past it right by the
    /// insertion's duration on the target track and every sync-locked track.
    public List<string> RippleInsertClips(
        IReadOnlyList<MediaAsset> assets, int trackIndex, int atFrame,
        IReadOnlyDictionary<string, (double Lower, double Upper)>? segments = null)
    {
        if (trackIndex < 0 || trackIndex >= Timeline.Tracks.Count)
        {
            return [];
        }
        segments ??= new Dictionary<string, (double, double)>();
        var created = new List<string>();
        WithTimelineSwap("Ripple Insert Clips", true, () =>
        {
            var totalPush = assets.Sum(a => ClipDurationFrames(a, segments.TryGetValue(a.Id, out var s) ? s : null));

            for (var ti = 0; ti < Timeline.Tracks.Count; ti++)
            {
                if (ti != trackIndex && !Timeline.Tracks[ti].SyncLocked)
                {
                    continue;
                }
                ApplyShifts(RippleEngine.ComputeRipplePush(Timeline.Tracks[ti].Clips, atFrame, totalPush));
            }
            created = CreateClips(assets, trackIndex, atFrame, segments: segments);
            SortClips(trackIndex);
        });
        return created;
    }

    // MARK: - Internal

    private void TrimClipInternal(string clipId, int trimStartFrame, int trimEndFrame, ISet<string>? protecting = null)
    {
        protecting ??= new HashSet<string>();
        if (FindClip(clipId) is not { } loc)
        {
            return;
        }
        var ti = loc.TrackIndex;
        var clip = Timeline.Tracks[ti].Clips[loc.ClipIndex];
        var prevStart = clip.TrimStartFrame;
        var prevEnd = clip.TrimEndFrame;
        var prevDuration = clip.DurationFrames;
        // The incoming trim values are source frames; translate their deltas into timeline
        // frames before applying to StartFrame/DurationFrames.
        var deltaStartSource = trimStartFrame - prevStart;
        var deltaEndSource = trimEndFrame - prevEnd;
        var deltaStartTimeline = SwiftMath.RoundToInt(deltaStartSource / clip.Speed);
        var deltaEndTimeline = SwiftMath.RoundToInt(deltaEndSource / clip.Speed);
        var newDuration = prevDuration - deltaStartTimeline - deltaEndTimeline;
        var newStartFrame = clip.StartFrame + deltaStartTimeline;

        Document.UndoService.BeginGrouping();

        var prevStartFrame = clip.StartFrame;
        var prevEndFrame = clip.EndFrame;
        var newEndFrame = newStartFrame + newDuration;
        var protectedIds = new HashSet<string>(protecting) { clipId };
        if (newStartFrame < prevStartFrame)
        {
            ClearRegion(ti, newStartFrame, prevStartFrame, prune: false, excluding: protectedIds);
        }
        if (newEndFrame > prevEndFrame)
        {
            ClearRegion(ti, prevEndFrame, newEndFrame, prune: false, excluding: protectedIds);
        }

        if (FindClip(clipId) is not { } refreshedLoc)
        {
            Document.UndoService.EndGrouping();
            return;
        }
        Timeline.Tracks[refreshedLoc.TrackIndex].Clips[refreshedLoc.ClipIndex].TrimStartFrame = trimStartFrame;
        Timeline.Tracks[refreshedLoc.TrackIndex].Clips[refreshedLoc.ClipIndex].TrimEndFrame = trimEndFrame;
        Timeline.Tracks[refreshedLoc.TrackIndex].Clips[refreshedLoc.ClipIndex].StartFrame = newStartFrame;
        Timeline.Tracks[refreshedLoc.TrackIndex].Clips[refreshedLoc.ClipIndex].SetDuration(newDuration);

        SortClips(refreshedLoc.TrackIndex);

        RegisterTimelineUndo("Trim Clip", () => TrimClipInternal(clipId, prevStart, prevEnd, protecting));
        Document.UndoService.EndGrouping();
        Document.UndoService.SetActionName("Trim Clip");
        NotifyTimelineChanged();
    }

    // MARK: - Validation

    /// Dry-run: returns a blocking reason (collision or negative startFrame) or null if safe.
    private string? ValidateShifts(int trackIndex, IReadOnlyList<ClipShift> shifts)
    {
        if (shifts.Count == 0 || trackIndex < 0 || trackIndex >= Timeline.Tracks.Count)
        {
            return null;
        }
        var track = Timeline.Tracks[trackIndex];
        var label = TimelineTrackDisplayLabel(trackIndex);
        var shiftMap = shifts.ToDictionary(s => s.ClipId, s => s.NewStartFrame);
        var intervals = new List<FrameRange>();
        foreach (var clip in track.Clips)
        {
            var start = shiftMap.TryGetValue(clip.Id, out var s) ? s : clip.StartFrame;
            if (start < 0)
            {
                return $"Sync-locked track \"{label}\" would move past the timeline start.";
            }
            intervals.Add(new FrameRange(start, start + clip.DurationFrames));
        }
        intervals = [.. intervals.OrderBy(i => i.Start)];
        for (var i = 1; i < intervals.Count; i++)
        {
            if (intervals[i].Start < intervals[i - 1].End)
            {
                return $"Sync-locked track \"{label}\" doesn't have room to ripple.";
            }
        }
        return null;
    }

    /// Refuses a ripple edit — raises `EditRefused` for a future toast/beep service to consume.
    private void RefuseRipple(string reason) => RaiseEditRefused(reason);
}
