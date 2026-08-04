using PalmierPro.Core.Models;
using PalmierPro.Core.Serialization;

namespace PalmierPro.Core.Editing;

/// <summary>Serialized clipboard payload: clips with offsets relative to the selection origin.</summary>
public sealed class ClipboardPayload
{
    public sealed class Entry
    {
        public required Clip Clip { get; set; }
        public int TrackOffset { get; set; }
        public int FrameOffset { get; set; }
        public required ClipType TrackType { get; set; }
    }

    public List<Entry> Entries { get; set; } = [];

    /// <summary>Track index of the selection's topmost clip, so paste can default there.</summary>
    public int BaseTrackIndex { get; set; }
}

public sealed partial class TimelineEditOperations
{
    // MARK: - Track operations

    /// <summary>All visual tracks stay above all audio tracks.</summary>
    private int PartitionedInsertionIndex(int requested, ClipType type)
    {
        var firstAudio = Timeline.Tracks.FindIndex(t => t.Type == ClipType.Audio);
        if (type == ClipType.Audio)
        {
            var min = firstAudio < 0 ? Timeline.Tracks.Count : firstAudio;
            return Math.Clamp(requested, min, Timeline.Tracks.Count);
        }
        var max = firstAudio < 0 ? Timeline.Tracks.Count : firstAudio;
        return Math.Clamp(requested, 0, max);
    }

    /// <summary>Inserts a track clamped into its video/audio zone. Returns the actual index.</summary>
    public int InsertTrack(int at, ClipType type)
    {
        var index = PartitionedInsertionIndex(at, type);
        MutateWithTimelineSwap("Add Track", () =>
            Timeline.Tracks.Insert(index, new Track { Type = type }));
        return index;
    }

    public bool RemoveTracks(IReadOnlyCollection<int> trackIndexes)
    {
        var valid = trackIndexes
            .Where(i => i >= 0 && i < Timeline.Tracks.Count)
            .Distinct()
            .OrderByDescending(i => i)
            .ToList();
        if (valid.Count == 0) return false;

        MutateWithTimelineSwap(valid.Count == 1 ? "Remove Track" : "Remove Tracks", () =>
        {
            foreach (var index in valid) Timeline.Tracks.RemoveAt(index);
        });
        return true;
    }

    public bool ToggleTrackMute(int trackIndex)
    {
        if (trackIndex < 0 || trackIndex >= Timeline.Tracks.Count) return false;
        var track = Timeline.Tracks[trackIndex];
        MutateWithTimelineSwap(track.Muted ? "Unmute Track" : "Mute Track", () =>
            track.Muted = !track.Muted);
        return true;
    }

    public bool ToggleTrackHidden(int trackIndex)
    {
        if (trackIndex < 0 || trackIndex >= Timeline.Tracks.Count) return false;
        var track = Timeline.Tracks[trackIndex];
        MutateWithTimelineSwap(track.Hidden ? "Show Track" : "Hide Track", () =>
            track.Hidden = !track.Hidden);
        return true;
    }

    /// <summary>Sync-lock toggle; refused when the track carries multicam clips.</summary>
    public bool ToggleTrackSyncLock(int trackIndex)
    {
        if (trackIndex < 0 || trackIndex >= Timeline.Tracks.Count) return false;
        var track = Timeline.Tracks[trackIndex];
        if (track.Clips.Any(c => c.MulticamGroupId is not null)) return false;
        MutateWithTimelineSwap(track.SyncLocked ? "Sync Unlock Track" : "Sync Lock Track", () =>
            track.SyncLocked = !track.SyncLocked);
        return true;
    }

    public bool SetTrackHeight(int trackIndex, double height)
    {
        if (trackIndex < 0 || trackIndex >= Timeline.Tracks.Count) return false;
        var clamped = Math.Clamp(height, TrackSize.MinHeight, TrackSize.MaxHeight);
        var track = Timeline.Tracks[trackIndex];
        if (Math.Abs(track.DisplayHeight - clamped) < 0.5) return false;
        MutateWithTimelineSwap("Resize Track", () => track.DisplayHeight = clamped);
        return true;
    }

    /// <summary>Removes empty tracks. Call inside an open mutation only.</summary>
    private void PruneEmptyTracks()
        => Timeline.Tracks.RemoveAll(t => t.Clips.Count == 0);

    // MARK: - Clipboard

    /// <summary>Copies clips with offsets relative to the top-left of the selection.</summary>
    public string? CopyClips(IReadOnlyCollection<string> clipIds)
    {
        var entries = new List<ClipboardPayload.Entry>();
        var located = new List<(int TrackIndex, Clip Clip)>();
        for (var trackIndex = 0; trackIndex < Timeline.Tracks.Count; trackIndex++)
        {
            foreach (var clip in Timeline.Tracks[trackIndex].Clips)
            {
                if (clipIds.Contains(clip.Id)) located.Add((trackIndex, clip));
            }
        }
        if (located.Count == 0) return null;

        var minTrack = located.Min(l => l.TrackIndex);
        var minFrame = located.Min(l => l.Clip.StartFrame);
        foreach (var (trackIndex, clip) in located)
        {
            entries.Add(new ClipboardPayload.Entry
            {
                Clip = Clone(clip),
                TrackOffset = trackIndex - minTrack,
                FrameOffset = clip.StartFrame - minFrame,
                TrackType = Timeline.Tracks[trackIndex].Type,
            });
        }
        return PalmierJson.EncodeToString(new ClipboardPayload
        {
            Entries = entries,
            BaseTrackIndex = minTrack,
        });
    }

    /// <summary>Pastes at the playhead on the tracks the clips were copied from.</summary>
    public List<string> PasteClipsAtPlayhead(string payloadJson, int playheadFrame)
    {
        ClipboardPayload? payload;
        try
        {
            payload = PalmierJson.Decode<ClipboardPayload>(payloadJson);
        }
        catch (Exception)
        {
            return [];
        }
        if (payload is null) return [];
        return PasteClips(payloadJson, payload.BaseTrackIndex, Math.Max(0, playheadFrame));
    }

    /// <summary>
    /// Pastes a clipboard payload with the selection origin at (atTrack, atFrame).
    /// Entries landing on incompatible tracks are skipped; overlaps are overwritten.
    /// Returns new clip ids.
    /// </summary>
    public List<string> PasteClips(string payloadJson, int atTrack, int atFrame)
    {
        ClipboardPayload? payload;
        try
        {
            payload = PalmierJson.Decode<ClipboardPayload>(payloadJson);
        }
        catch (Exception)
        {
            return [];
        }
        if (payload is null || payload.Entries.Count == 0) return [];

        var placements = new List<(Clip Clip, int TrackIndex, int Frame)>();
        foreach (var entry in payload.Entries)
        {
            var trackIndex = atTrack + entry.TrackOffset;
            if (trackIndex < 0 || trackIndex >= Timeline.Tracks.Count) continue;
            if (!entry.Clip.MediaType.IsCompatible(Timeline.Tracks[trackIndex].Type)) continue;
            var frame = Math.Max(0, atFrame + entry.FrameOffset);
            placements.Add((Clone(entry.Clip), trackIndex, frame));
        }
        if (placements.Count == 0) return [];

        FreshenIds(placements.Select(p => p.Clip).ToList());
        var newIds = new List<string>();
        MutateWithTimelineSwap(placements.Count == 1 ? "Paste Clip" : "Paste Clips", () =>
        {
            foreach (var (clip, trackIndex, frame) in placements)
            {
                ClearRegion(trackIndex, frame, frame + clip.DurationFrames);
                clip.StartFrame = frame;
                Timeline.Tracks[trackIndex].Clips.Add(clip);
                newIds.Add(clip.Id);
            }
            SortAllTracks();
        });
        return newIds;
    }

    /// <summary>Option-drag landing: clones the clips at explicit positions.</summary>
    public List<string> DuplicateClipsToPositions(
        IReadOnlyList<(string ClipId, int ToTrack, int ToFrame)> placements)
    {
        var clones = new List<(Clip Clip, int TrackIndex, int Frame)>();
        foreach (var (clipId, toTrack, toFrame) in placements)
        {
            if (toTrack < 0 || toTrack >= Timeline.Tracks.Count) continue;
            if (FindClip(clipId) is not { } found) continue;
            if (!found.Clip.MediaType.IsCompatible(Timeline.Tracks[toTrack].Type)) continue;
            clones.Add((Clone(found.Clip), toTrack, Math.Max(0, toFrame)));
        }
        if (clones.Count == 0) return [];

        FreshenIds(clones.Select(c => c.Clip).ToList());
        var newIds = new List<string>();
        MutateWithTimelineSwap(clones.Count == 1 ? "Duplicate Clip" : "Duplicate Clips", () =>
        {
            foreach (var (clip, trackIndex, frame) in clones)
            {
                ClearRegion(trackIndex, frame, frame + clip.DurationFrames);
                clip.StartFrame = frame;
                Timeline.Tracks[trackIndex].Clips.Add(clip);
                newIds.Add(clip.Id);
            }
            SortAllTracks();
        });
        return newIds;
    }

    /// <summary>
    /// New ids for cloned clips; multicam membership is cleared and link groups are
    /// remapped only when at least two members of the same group clone together.
    /// </summary>
    private static void FreshenIds(IReadOnlyList<Clip> clips)
    {
        var groupCounts = clips
            .Where(c => c.LinkGroupId is not null)
            .GroupBy(c => c.LinkGroupId!)
            .ToDictionary(g => g.Key, g => g.Count());
        var remapped = new Dictionary<string, string>();

        foreach (var clip in clips)
        {
            clip.Id = Uuid.NewString();
            clip.MulticamGroupId = null;
            if (clip.LinkGroupId is { } group)
            {
                if (groupCounts.GetValueOrDefault(group) >= 2)
                {
                    if (!remapped.TryGetValue(group, out var fresh))
                    {
                        fresh = Uuid.NewString();
                        remapped[group] = fresh;
                    }
                    clip.LinkGroupId = fresh;
                }
                else
                {
                    clip.LinkGroupId = null;
                }
            }
        }
    }
}
