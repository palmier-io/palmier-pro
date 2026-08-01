using PalmierPro.Core.Models;
using PalmierPro.Core.Serialization;
using PalmierPro.Core.Undo;

namespace PalmierPro.Core.Editing;

/// <summary>
/// Domain mutation operations shared by the timeline UI and (later) Agent tools.
/// Each public operation validates first, mutates atomically, and produces exactly
/// one undoable action. Linked clips move and delete together.
/// </summary>
public sealed class TimelineEditOperations(Timeline timeline, EditorUndo undo)
{
    public Timeline Timeline { get; } = timeline;

    /// <summary>Raised after any successful mutation (including undo/redo) so owners can save and rebuild playback.</summary>
    public event Action? TimelineChanged;

    public (int TrackIndex, Clip Clip)? FindClip(string clipId)
    {
        for (var trackIndex = 0; trackIndex < Timeline.Tracks.Count; trackIndex++)
        {
            var clip = Timeline.Tracks[trackIndex].Clips.FirstOrDefault(c => c.Id == clipId);
            if (clip is not null) return (trackIndex, clip);
        }
        return null;
    }

    /// <summary>Linked companions (same link group) excluding the clip itself.</summary>
    public List<(int TrackIndex, Clip Clip)> LinkedCompanions(Clip clip)
    {
        if (clip.LinkGroupId is not { } linkId) return [];
        var companions = new List<(int, Clip)>();
        for (var trackIndex = 0; trackIndex < Timeline.Tracks.Count; trackIndex++)
        {
            foreach (var candidate in Timeline.Tracks[trackIndex].Clips)
            {
                if (candidate.Id != clip.Id && candidate.LinkGroupId == linkId)
                    companions.Add((trackIndex, candidate));
            }
        }
        return companions;
    }

    /// <summary>
    /// Moves a clip to a new start frame (linked companions follow the frame delta on
    /// their own tracks). Returns false if the clip is missing or the move is a no-op.
    /// </summary>
    public bool MoveClip(string clipId, int newStartFrame)
    {
        if (newStartFrame < 0) return false;
        if (FindClip(clipId) is not { } found) return false;
        var delta = newStartFrame - found.Clip.StartFrame;
        if (delta == 0) return false;

        var movers = new List<Clip> { found.Clip };
        movers.AddRange(LinkedCompanions(found.Clip).Select(c => c.Clip));
        if (movers.Any(c => c.StartFrame + delta < 0)) return false;

        var before = movers.Select(c => (Clip: c, Start: c.StartFrame)).ToList();
        var after = movers.Select(c => (Clip: c, Start: c.StartFrame + delta)).ToList();
        Mutate("Move Clip",
            restore: () => { foreach (var (clip, start) in before) clip.StartFrame = start; },
            apply: () =>
            {
                foreach (var (clip, start) in after) clip.StartFrame = start;
                ResortTracksContaining(movers);
            });
        return true;
    }

    /// <summary>
    /// Trims a clip to a new start/duration. The caller supplies the matching trimStart
    /// so source alignment is preserved (left trims shift it, right trims do not).
    /// </summary>
    public bool TrimClip(string clipId, int newStartFrame, int newDurationFrames, int newTrimStartFrame)
    {
        if (newStartFrame < 0 || newDurationFrames < 1 || newTrimStartFrame < 0) return false;
        if (FindClip(clipId) is not { } found) return false;
        var clip = found.Clip;
        var before = (clip.StartFrame, clip.DurationFrames, clip.TrimStartFrame);
        if (before == (newStartFrame, newDurationFrames, newTrimStartFrame)) return false;

        Mutate("Trim Clip",
            restore: () =>
                (clip.StartFrame, clip.DurationFrames, clip.TrimStartFrame) = before,
            apply: () =>
            {
                clip.StartFrame = newStartFrame;
                clip.DurationFrames = newDurationFrames;
                clip.TrimStartFrame = newTrimStartFrame;
                ResortTracksContaining([clip]);
            });
        return true;
    }

    /// <summary>Deletes the clips (already link-expanded by selection). Returns removed count.</summary>
    public int DeleteClips(IReadOnlyCollection<string> clipIds)
    {
        var removals = new List<(Track Track, int Index, Clip Clip)>();
        foreach (var track in Timeline.Tracks)
        {
            for (var i = 0; i < track.Clips.Count; i++)
            {
                if (clipIds.Contains(track.Clips[i].Id))
                    removals.Add((track, i, track.Clips[i]));
            }
        }
        if (removals.Count == 0) return 0;

        Mutate(removals.Count == 1 ? "Delete Clip" : "Delete Clips",
            restore: () =>
            {
                // Reinsert ascending so stored indexes stay valid.
                foreach (var (track, index, clip) in removals.OrderBy(r => r.Index))
                    track.Clips.Insert(Math.Min(index, track.Clips.Count), clip);
            },
            apply: () =>
            {
                foreach (var (track, _, clip) in removals) track.Clips.Remove(clip);
            });
        return removals.Count;
    }

    /// <summary>Splits a clip at a timeline frame strictly inside it. Returns the new right clip id.</summary>
    public string? SplitClip(string clipId, int frame)
    {
        if (FindClip(clipId) is not { } found) return null;
        var clip = found.Clip;
        if (frame <= clip.StartFrame || frame >= clip.EndFrame) return null;

        var leftDuration = frame - clip.StartFrame;
        var right = Clone(clip);
        right.Id = Uuid.NewString();
        right.StartFrame = frame;
        right.DurationFrames = clip.DurationFrames - leftDuration;
        right.TrimStartFrame = clip.TrimStartFrame
            + (int)Math.Round(leftDuration * clip.Speed, MidpointRounding.AwayFromZero);
        right.FadeInFrames = 0;

        var track = Timeline.Tracks[found.TrackIndex];
        var before = (clip.DurationFrames, clip.FadeOutFrames);

        Mutate("Split Clip",
            restore: () =>
            {
                (clip.DurationFrames, clip.FadeOutFrames) = before;
                track.Clips.Remove(right);
            },
            apply: () =>
            {
                clip.DurationFrames = leftDuration;
                clip.FadeOutFrames = 0;
                var insertIndex = track.Clips.IndexOf(clip) + 1;
                track.Clips.Insert(insertIndex, right);
            });
        return right.Id;
    }

    private static Clip Clone(Clip clip)
        => PalmierJson.Decode<Clip>(PalmierJson.Encode(clip))
            ?? throw new InvalidOperationException("Clip clone round-trip failed");

    /// <summary>Applies a mutation and registers a self-reversing undo pair.</summary>
    private void Mutate(string actionName, Action restore, Action apply)
    {
        undo.Perform(actionName, () =>
        {
            RegisterSwap(actionName, restore, apply);
            apply();
        });
        TimelineChanged?.Invoke();
    }

    private void RegisterSwap(string actionName, Action restore, Action reapply)
    {
        undo.Register(actionName, () =>
        {
            restore();
            // Registration during undo lands on the redo stack (and vice versa).
            RegisterSwap(actionName, reapply, restore);
            TimelineChanged?.Invoke();
        });
    }

    private void ResortTracksContaining(IReadOnlyCollection<Clip> clips)
    {
        foreach (var track in Timeline.Tracks)
        {
            if (track.Clips.Any(clips.Contains))
                track.Clips.Sort((a, b) => a.StartFrame.CompareTo(b.StartFrame));
        }
    }
}
