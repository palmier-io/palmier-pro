using PalmierPro.Core.Models;

namespace PalmierPro.Core.Editing;

/// <summary>Half-open frame range [Start, End).</summary>
public readonly record struct FrameRange(int Start, int End)
{
    public int Length => End - Start;
    public bool IsValid => End > Start;
    public bool Contains(int frame) => frame >= Start && frame < End;
}

public readonly record struct ClipShift(string ClipId, int NewStartFrame);

/// <summary>
/// Pure ripple math mirroring the Mac RippleEngine: closing removed ranges shifts
/// every clip left by the total length of merged ranges entirely to its left, and
/// insertion pushes clips at or after the insert frame right.
/// </summary>
public static class RippleEngine
{
    public static List<FrameRange> MergeRanges(IReadOnlyList<FrameRange> ranges)
    {
        var valid = ranges.Where(r => r.IsValid).OrderBy(r => r.Start).ToList();
        var merged = new List<FrameRange>();
        foreach (var range in valid)
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

    public static List<ClipShift> ComputeRippleShiftsForRanges(
        IReadOnlyList<Clip> clips, IReadOnlyList<FrameRange> removedRanges)
    {
        var merged = MergeRanges(removedRanges);
        var shifts = new List<ClipShift>();
        foreach (var clip in clips.OrderBy(c => c.StartFrame))
        {
            var shift = merged.Where(r => r.End <= clip.StartFrame).Sum(r => r.Length);
            if (shift > 0) shifts.Add(new ClipShift(clip.Id, clip.StartFrame - shift));
        }
        return shifts;
    }

    public static List<ClipShift> ComputePushShifts(
        IReadOnlyList<Clip> clips, int insertFrame, int pushAmount)
    {
        if (pushAmount <= 0) return [];
        return clips
            .Where(c => c.StartFrame >= insertFrame)
            .Select(c => new ClipShift(c.Id, c.StartFrame + pushAmount))
            .ToList();
    }
}
