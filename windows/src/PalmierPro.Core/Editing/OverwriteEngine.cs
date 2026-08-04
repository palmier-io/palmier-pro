using PalmierPro.Core.Models;
using PalmierPro.Core.Serialization;

namespace PalmierPro.Core.Editing;

/// <summary>
/// Pure overwrite collision math mirroring the Mac OverwriteEngine. Classifies each
/// clip intersecting a half-open region into remove, trim-end, trim-start, or split,
/// with source trims converted through the clip's speed.
/// </summary>
public static class OverwriteEngine
{
    public abstract record ClearAction
    {
        public sealed record Remove(string ClipId) : ClearAction;
        public sealed record TrimEnd(string ClipId, int NewDurationFrames) : ClearAction;
        public sealed record TrimStart(string ClipId, int NewStartFrame, int NewDurationFrames, int NewTrimStartFrame) : ClearAction;
        public sealed record Split(
            string ClipId, int LeftDurationFrames,
            int RightStartFrame, int RightDurationFrames, int RightTrimStartFrame) : ClearAction;
    }

    public static List<ClearAction> ClearActions(
        IReadOnlyList<Clip> clips, int regionStart, int regionEnd,
        IReadOnlySet<string>? excluding = null)
    {
        var actions = new List<ClearAction>();
        if (regionEnd <= regionStart) return actions;

        foreach (var clip in clips)
        {
            if (excluding?.Contains(clip.Id) == true) continue;
            var clipStart = clip.StartFrame;
            var clipEnd = clip.EndFrame;
            if (clipEnd <= regionStart || clipStart >= regionEnd) continue;

            if (clipStart >= regionStart && clipEnd <= regionEnd)
            {
                actions.Add(new ClearAction.Remove(clip.Id));
            }
            else if (clipStart < regionStart && clipEnd > regionEnd)
            {
                var leftDuration = regionStart - clipStart;
                var rightTrimStart = clip.TrimStartFrame
                    + (int)Math.Round((regionEnd - clipStart) * clip.Speed, MidpointRounding.AwayFromZero);
                actions.Add(new ClearAction.Split(
                    clip.Id, leftDuration, regionEnd, clipEnd - regionEnd, rightTrimStart));
            }
            else if (clipStart < regionStart)
            {
                actions.Add(new ClearAction.TrimEnd(clip.Id, regionStart - clipStart));
            }
            else
            {
                var trimAmount = regionEnd - clipStart;
                var newTrimStart = clip.TrimStartFrame
                    + (int)Math.Round(trimAmount * clip.Speed, MidpointRounding.AwayFromZero);
                actions.Add(new ClearAction.TrimStart(
                    clip.Id, regionEnd, clipEnd - regionEnd, newTrimStart));
            }
        }
        return actions;
    }

    /// <summary>Applies clear actions to a track's clip list, keeping it sorted by start.</summary>
    public static void Apply(Track track, IReadOnlyList<ClearAction> actions)
    {
        foreach (var action in actions)
        {
            switch (action)
            {
                case ClearAction.Remove remove:
                    track.Clips.RemoveAll(c => c.Id == remove.ClipId);
                    break;

                case ClearAction.TrimEnd trimEnd:
                {
                    if (Find(track, trimEnd.ClipId) is not { } clip) break;
                    var removedTimeline = clip.DurationFrames - trimEnd.NewDurationFrames;
                    clip.TrimEndFrame += (int)Math.Round(removedTimeline * clip.Speed, MidpointRounding.AwayFromZero);
                    clip.SetDuration(trimEnd.NewDurationFrames);
                    break;
                }

                case ClearAction.TrimStart trimStart:
                {
                    if (Find(track, trimStart.ClipId) is not { } clip) break;
                    clip.StartFrame = trimStart.NewStartFrame;
                    clip.TrimStartFrame = trimStart.NewTrimStartFrame;
                    clip.SetDuration(trimStart.NewDurationFrames);
                    break;
                }

                case ClearAction.Split split:
                {
                    if (Find(track, split.ClipId) is not { } clip) break;
                    var right = PalmierJson.Decode<Clip>(PalmierJson.Encode(clip))
                        ?? throw new InvalidOperationException("Clip clone round-trip failed");
                    right.Id = Uuid.NewString();
                    right.StartFrame = split.RightStartFrame;
                    right.TrimStartFrame = split.RightTrimStartFrame;
                    right.DurationFrames = split.RightDurationFrames;
                    right.FadeInFrames = 0;
                    right.ClampFadesToDuration();
                    right.ClampKeyframesToDuration();

                    clip.FadeOutFrames = 0;
                    clip.SetDuration(split.LeftDurationFrames);

                    var insertIndex = track.Clips.IndexOf(clip) + 1;
                    track.Clips.Insert(insertIndex, right);
                    break;
                }
            }
        }
        track.Clips.Sort((a, b) => a.StartFrame.CompareTo(b.StartFrame));
    }

    private static Clip? Find(Track track, string clipId)
        => track.Clips.FirstOrDefault(c => c.Id == clipId);
}
