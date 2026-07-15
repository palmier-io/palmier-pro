using PalmierPro.Core;
using PalmierPro.Core.Json;
using PalmierPro.Core.Models;
using PalmierPro.Core.Timeline;

namespace PalmierPro.App.ViewModels.Editor;

/// Snapshot of the video/audio track partition. Video/image tracks sit at indices
/// `[0, FirstAudioIndex)`; audio tracks at `[FirstAudioIndex, TrackCount)`. Ported from
/// `EditorViewModel+Linking.swift`'s `ZoneLayout`.
public readonly record struct ZoneLayout(int TrackCount, int FirstAudioIndex)
{
    public int VideoTrackCount => FirstAudioIndex;
    public int AudioTrackCount => TrackCount - FirstAudioIndex;
}

/// Link groups: clips that share a `LinkGroupId` behave as one unit for selection, move, trim,
/// and delete. Ported from the corresponding slice of `EditorViewModel+Linking.swift` — drop-plan
/// / track-zone-routing-for-drops helpers (`resolveVisualDropTarget` and friends) are UI-drag
/// concerns for a future timeline drag controller (Stage D/E), not core mutations, and are not
/// ported here. `LinkGroupOffsets`'s multicam-cluster half is also not ported: it reduces to a
/// no-op today, since no `MulticamEngine` exists on Windows yet and `Clip.MulticamGroupId` is
/// always null (see this class's own "Not ported" note) — only the `LinkGroupId` half is ported.
public sealed partial class TimelineEditorViewModel
{
    /// Video/audio zone partition.
    public ZoneLayout Zones
    {
        get
        {
            var count = Timeline.Tracks.Count;
            var firstAudio = Timeline.Tracks.FindIndex(t => t.Type == ClipType.Audio);
            return new ZoneLayout(count, firstAudio < 0 ? count : firstAudio);
        }
    }

    /// Reverse link-group index — built in a single pass.
    public Dictionary<string, List<string>> LinkIndex
    {
        get
        {
            var m = new Dictionary<string, List<string>>();
            foreach (var track in Timeline.Tracks)
            {
                foreach (var clip in track.Clips)
                {
                    if (clip.LinkGroupId is not { } g)
                    {
                        continue;
                    }
                    if (!m.TryGetValue(g, out var members))
                    {
                        members = [];
                        m[g] = members;
                    }
                    members.Add(clip.Id);
                }
            }
            return m;
        }
    }

    /// Returns every clip id sharing a link group with any id in `ids`, including the inputs
    /// themselves.
    public HashSet<string> ExpandToLinkGroup(IEnumerable<string> ids)
    {
        var idSet = new HashSet<string>(ids);
        var idx = LinkIndex;
        var clipToGroup = new Dictionary<string, string>();
        foreach (var (gid, members) in idx)
        {
            foreach (var id in members)
            {
                clipToGroup[id] = gid;
            }
        }
        var groups = new HashSet<string>();
        foreach (var id in idSet)
        {
            if (clipToGroup.TryGetValue(id, out var g))
            {
                groups.Add(g);
            }
        }
        if (groups.Count == 0)
        {
            return idSet;
        }
        var result = new HashSet<string>(idSet);
        foreach (var g in groups)
        {
            if (idx.TryGetValue(g, out var members))
            {
                result.UnionWith(members);
            }
        }
        return result;
    }

    /// Ids of clips that share `clipId`'s link group, excluding `clipId` itself.
    public List<string> LinkedPartnerIds(string clipId)
    {
        foreach (var (_, members) in LinkIndex)
        {
            if (members.Contains(clipId))
            {
                return [.. members.Where(id => id != clipId)];
            }
        }
        return [];
    }

    // MARK: - Out-of-sync offset

    /// Out-of-sync offset (in frames) for every linked clip, keyed by clip id. Clips in sync (or
    /// unlinked) are absent from the result. Ported from `linkGroupOffsets`'s `LinkGroupId` half —
    /// see this file's doc comment for why the multicam-cluster half is not ported.
    public Dictionary<string, int> LinkGroupOffsets()
    {
        var byGroup = new Dictionary<string, List<(string Id, int Start)>>();
        foreach (var track in Timeline.Tracks)
        {
            foreach (var clip in track.Clips)
            {
                if (clip.LinkGroupId is not { } gid)
                {
                    continue;
                }
                if (!byGroup.TryGetValue(gid, out var entries))
                {
                    entries = [];
                    byGroup[gid] = entries;
                }
                entries.Add((clip.Id, clip.StartFrame - clip.TrimStartFrame));
            }
        }
        var offsets = new Dictionary<string, int>();
        foreach (var entries in byGroup.Values)
        {
            if (entries.Count <= 1)
            {
                continue;
            }
            var reference = entries.Min(e => e.Start);
            foreach (var entry in entries)
            {
                if (entry.Start != reference)
                {
                    offsets[entry.Id] = entry.Start - reference;
                }
            }
        }
        return offsets;
    }

    // MARK: - Link / Unlink commands

    /// Stamps a new link group on every clip in `ids`, merging pre-existing sub-groups into the
    /// new group. Linking a single clip is meaningless, so fewer than two ids is a no-op.
    public void LinkClips(ISet<string> ids)
    {
        if (ids.Count < 2)
        {
            return;
        }
        var newGroup = SwiftId.New();
        MutateClips(ids, "Link", c => c.LinkGroupId = newGroup);
    }

    /// Clears the link group on every clip that shares a group with any id in `ids`.
    public void UnlinkClips(ISet<string> ids)
    {
        var expanded = new HashSet<string>(ExpandToLinkGroup(ids).Where(id =>
            FindClip(id) is { } loc && Timeline.Tracks[loc.TrackIndex].Clips[loc.ClipIndex].LinkGroupId is not null));
        MutateClips(expanded, "Unlink", c => c.LinkGroupId = null);
        SelectedClipIds = [];
    }

    public enum TrimEdge
    {
        Left,
        Right,
    }

    /// Translates a timeline-frame trim delta into source-frame `TrimStartFrame`/`TrimEndFrame`
    /// deltas. Image/Text clips have no source-material bound, so their trim fields can go
    /// negative.
    public static (int TrimStart, int TrimEnd) TrimValues(Clip clip, TrimEdge edge, int delta)
    {
        var sourceDelta = SwiftMath.RoundToInt(delta * clip.Speed);
        var unbounded = clip.MediaType is ClipType.Image or ClipType.Text;
        if (edge == TrimEdge.Left)
        {
            var newStart = clip.TrimStartFrame + sourceDelta;
            return (unbounded ? newStart : Math.Max(0, newStart), clip.TrimEndFrame);
        }
        var newEnd = clip.TrimEndFrame - sourceDelta;
        return (clip.TrimStartFrame, unbounded ? newEnd : Math.Max(0, newEnd));
    }

    /// First audio track with no overlap at `[startFrame, startFrame + duration)`, else null.
    public int? AvailableAudioTrackIndex(int startFrame, int duration)
    {
        var z = Zones;
        for (var i = z.FirstAudioIndex; i < z.TrackCount; i++)
        {
            var conflicts = Timeline.Tracks[i].Clips.Any(c => !(c.EndFrame <= startFrame || c.StartFrame >= startFrame + duration));
            if (!conflicts)
            {
                return i;
            }
        }
        return null;
    }

    public int ResolveOrCreateAudioTrack(int startFrame, int duration) =>
        AvailableAudioTrackIndex(startFrame, duration) ?? InsertTrack(Timeline.Tracks.Count, ClipType.Audio);
}
