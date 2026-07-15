using PalmierPro.Core.Models;

namespace PalmierPro.Core.Timeline;

/// A proposed new start frame for a single clip, produced by the ripple engine and applied by the
/// caller. Ported from Editor/RippleEngine.swift.
public readonly record struct ClipShift(string ClipId, int NewStartFrame);

/// A half-open `[Start, End)` frame interval on a single track.
public readonly record struct FrameRange(int Start, int End)
{
    public int Length => End - Start;
}

/// A user-selected empty gap on a single track.
public readonly record struct GapSelection(int TrackIndex, FrameRange Range);

/// Pure functions for ripple editing: computing how clips shift after insertions or deletions.
/// Ported near-verbatim from Editor/RippleEngine.swift.
public static class RippleEngine
{
    /// After removing clips from a track, compute new start frames for remaining clips that
    /// should shift backward to close the gap.
    public static List<ClipShift> ComputeRippleShifts(IReadOnlyList<Clip> clips, ISet<string> removedIds)
    {
        var removedRanges = clips
            .Where(c => removedIds.Contains(c.Id))
            .Select(c => new FrameRange(c.StartFrame, c.EndFrame))
            .ToList();
        return ComputeRippleShiftsForRanges(clips.Where(c => !removedIds.Contains(c.Id)).ToList(), removedRanges);
    }

    /// Shift clips leftward to close the gaps defined by `removedRanges`. Used when ranges come
    /// from a different track (sync-locked ripple).
    public static List<ClipShift> ComputeRippleShiftsForRanges(IReadOnlyList<Clip> clips, IReadOnlyList<FrameRange> removedRanges)
    {
        var merged = MergeRanges(removedRanges);
        if (merged.Count == 0)
        {
            return [];
        }

        var shifts = new List<ClipShift>();
        foreach (var clip in clips.OrderBy(c => c.StartFrame))
        {
            var shift = merged.Where(r => r.End <= clip.StartFrame).Sum(r => r.Length);
            if (shift > 0)
            {
                shifts.Add(new ClipShift(clip.Id, clip.StartFrame - shift));
            }
        }
        return shifts;
    }

    /// Push all clips at or after `insertFrame` forward by `pushAmount` frames.
    public static List<ClipShift> ComputeRipplePush(
        IReadOnlyList<Clip> clips, int insertFrame, int pushAmount, ISet<string>? excludeIds = null)
    {
        excludeIds ??= new HashSet<string>();
        return clips
            .Where(c => !excludeIds.Contains(c.Id) && c.StartFrame >= insertFrame)
            .Select(c => new ClipShift(c.Id, c.StartFrame + pushAmount))
            .ToList();
    }

    public static List<FrameRange> MergeRanges(IReadOnlyList<FrameRange> ranges)
    {
        var sorted = ranges.OrderBy(r => r.Start).ToList();
        var merged = new List<FrameRange>();
        foreach (var range in sorted)
        {
            if (merged.Count > 0 && range.Start <= merged[^1].End)
            {
                merged[^1] = new FrameRange(merged[^1].Start, Math.Max(merged[^1].End, range.End));
            }
            else
            {
                merged.Add(range);
            }
        }
        return merged;
    }
}
