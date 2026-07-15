using PalmierPro.Core.Json;
using PalmierPro.Core.Models;

namespace PalmierPro.Core.Timeline;

/// Ported from Editor/OverwriteEngine.swift's `Action` enum. C# has no native sum type, so each
/// case is a record subtype of this abstract base; callers pattern-match with `switch`.
public abstract record OverwriteAction
{
    public sealed record Remove(string ClipId) : OverwriteAction;

    public sealed record TrimEnd(string ClipId, int NewDuration) : OverwriteAction;

    public sealed record TrimStart(string ClipId, int NewStartFrame, int NewTrimStart, int NewDuration) : OverwriteAction;

    public sealed record Split(
        string ClipId, int LeftDuration, string RightId, int RightStartFrame, int RightTrimStart, int RightDuration) : OverwriteAction;
}

/// Pure functions for overwrite editing: computing how to clear a region of the timeline by
/// removing, trimming, or splitting existing clips. Ported near-verbatim from
/// Editor/OverwriteEngine.swift.
public static class OverwriteEngine
{
    /// Given a region `[regionStart, regionEnd)` on a track, returns the actions needed to clear
    /// that region so a new clip can be placed there.
    public static List<OverwriteAction> ComputeOverwrite(IReadOnlyList<Clip> clips, int regionStart, int regionEnd)
    {
        if (regionEnd <= regionStart)
        {
            return [];
        }
        var actions = new List<OverwriteAction>();

        foreach (var clip in clips)
        {
            var cs = clip.StartFrame;
            var ce = clip.EndFrame;

            if (ce <= regionStart || cs >= regionEnd)
            {
                continue;
            }

            if (cs >= regionStart && ce <= regionEnd)
            {
                actions.Add(new OverwriteAction.Remove(clip.Id));
            }
            else if (cs < regionStart && ce > regionEnd)
            {
                var leftDuration = regionStart - cs;
                var rightStartFrame = regionEnd;
                var rightTrimStart = clip.TrimStartFrame + SwiftMath.RoundToInt((regionEnd - cs) * clip.Speed);
                var rightDuration = ce - regionEnd;
                actions.Add(new OverwriteAction.Split(clip.Id, leftDuration, SwiftId.New(), rightStartFrame, rightTrimStart, rightDuration));
            }
            else if (cs < regionStart)
            {
                // Overlaps left side — trim right edge.
                var newDuration = regionStart - cs;
                actions.Add(new OverwriteAction.TrimEnd(clip.Id, newDuration));
            }
            else
            {
                // Overlaps right side — trim left edge.
                var trimAmount = regionEnd - cs;
                var newStartFrame = regionEnd;
                var newTrimStart = clip.TrimStartFrame + SwiftMath.RoundToInt(trimAmount * clip.Speed);
                var newDuration = ce - regionEnd;
                actions.Add(new OverwriteAction.TrimStart(clip.Id, newStartFrame, newTrimStart, newDuration));
            }
        }

        return actions;
    }
}
