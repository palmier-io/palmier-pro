using PalmierPro.Core.Models;

namespace PalmierPro.App.ViewModels.Editor;

/// Track-level mutations: add/remove, visibility toggles, height, sync-lock. Ports
/// `EditorViewModel+Tracks.swift`. `ReorderTrackLive`/`CommitTrackReorder` (live drag reordering)
/// are UI-drag concerns for a future timeline drag controller (Stage D) and are not ported here.
public sealed partial class TimelineEditorViewModel
{
    // MARK: - Add / remove

    public int InsertTrack(int index, ClipType type)
    {
        var clamped = PartitionedInsertionIndex(type, index);
        var track = new Track(type);
        WithTimelineSwap("Add Track", true, () => Timeline.Tracks.Insert(clamped, track));
        return clamped;
    }

    /// "V1", "A1", "I1" label for the track at the given index.
    public string TimelineTrackDisplayLabel(int trackIndex)
    {
        if (trackIndex < 0 || trackIndex >= Timeline.Tracks.Count)
        {
            return "";
        }
        var type = Timeline.Tracks[trackIndex].Type;
        var n = 0;
        if (type == ClipType.Audio)
        {
            for (var i = 0; i <= trackIndex; i++)
            {
                if (Timeline.Tracks[i].Type == type)
                {
                    n++;
                }
            }
        }
        else
        {
            var upper = Math.Max(trackIndex + 1, Zones.FirstAudioIndex);
            for (var i = trackIndex; i < upper; i++)
            {
                if (Timeline.Tracks[i].Type == type)
                {
                    n++;
                }
            }
        }
        return $"{type.TrackLabelPrefix()}{n}";
    }

    /// Clamp `requested` so that visual (video/image) tracks always sit above every audio track.
    private int PartitionedInsertionIndex(ClipType type, int requested)
    {
        var z = Zones;
        var bounded = Math.Max(0, Math.Min(requested, z.TrackCount));
        return type switch
        {
            ClipType.Video or ClipType.Image or ClipType.Text or ClipType.Lottie or ClipType.Sequence => Math.Min(bounded, z.FirstAudioIndex),
            ClipType.Audio => Math.Max(bounded, z.FirstAudioIndex),
            _ => bounded,
        };
    }

    public void RemoveTrack(string id) => RemoveTracks([id]);

    public void RemoveTracks(IReadOnlyList<string> ids)
    {
        var set = new HashSet<string>(ids);
        if (!Timeline.Tracks.Any(t => set.Contains(t.Id)))
        {
            return;
        }
        WithTimelineSwap(set.Count == 1 ? "Remove Track" : "Remove Tracks", true, () =>
        {
            Timeline.Tracks.RemoveAll(t => set.Contains(t.Id));
        });
    }

    public void PruneEmptyTracks() => Timeline.Tracks.RemoveAll(t => t.Clips.Count == 0);

    // MARK: - Flag toggles

    public void ToggleTrackMute(int trackIndex) =>
        ToggleTrackFlag(trackIndex, t => t.Muted, (t, v) => t.Muted = v, "Mute Track", "Unmute Track");

    public void ToggleTrackHidden(int trackIndex) =>
        ToggleTrackFlag(trackIndex, t => t.Hidden, (t, v) => t.Hidden = v, "Hide Track", "Show Track");

    public void ToggleTrackSyncLock(int trackIndex) =>
        ToggleTrackFlag(trackIndex, t => t.SyncLocked, (t, v) => t.SyncLocked = v, "Sync Lock Track", "Unlock Track Sync");

    /// Flips a bool flag on a track, registers a reversing undo, and publishes the change.
    /// `onName` is used when the flag transitions false -> true; `offName` for true -> false.
    private void ToggleTrackFlag(int trackIndex, Func<Track, bool> get, Action<Track, bool> set, string onName, string offName)
    {
        if (trackIndex < 0 || trackIndex >= Timeline.Tracks.Count)
        {
            return;
        }
        var trackId = Timeline.Tracks[trackIndex].Id;
        var was = get(Timeline.Tracks[trackIndex]);
        set(Timeline.Tracks[trackIndex], !was);
        var actionName = was ? offName : onName;
        RegisterTimelineUndo(actionName, () =>
        {
            var idx = Timeline.Tracks.FindIndex(t => t.Id == trackId);
            if (idx >= 0)
            {
                set(Timeline.Tracks[idx], was);
            }
        });
        Document.UndoService.SetActionName(actionName);
        NotifyTimelineChanged();
    }

    // MARK: - Sizing

    public void SetTrackHeight(int trackIndex, double height)
    {
        if (trackIndex < 0 || trackIndex >= Timeline.Tracks.Count)
        {
            return;
        }
        var trackId = Timeline.Tracks[trackIndex].Id;
        var prev = Timeline.Tracks[trackIndex].DisplayHeight;
        Timeline.Tracks[trackIndex].DisplayHeight = Math.Max(TrackSize.MinHeight, Math.Min(TrackSize.MaxHeight, height));
        RegisterTimelineUndo("Resize Track", () =>
        {
            var idx = Timeline.Tracks.FindIndex(t => t.Id == trackId);
            if (idx >= 0)
            {
                SetTrackHeight(idx, prev);
            }
        });
        Document.UndoService.SetActionName("Resize Track");
    }
}
