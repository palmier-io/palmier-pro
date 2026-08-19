using PalmierPro.Core.Models;

namespace PalmierPro.Agent.Tools;

/// <summary>Mac-shaped mutation receipts: changed clips, shifts, removals.</summary>
internal static class MutationDelta
{
    private const int ClipLimit = 30;
    private const int ShiftGroupMinimum = 3;

    public sealed record ClipPlacement(string TrackId, int Index, int Start, int Duration)
    {
        public bool SamePlace(ClipPlacement other)
            => TrackId == other.TrackId && Start == other.Start && Duration == other.Duration;
    }

    public sealed record TimelineSnapshot(
        IReadOnlyDictionary<string, ClipPlacement> Placements,
        IReadOnlyList<string> TrackIds);

    public static TimelineSnapshot Snapshot(Timeline timeline)
    {
        var placements = new Dictionary<string, ClipPlacement>();
        var trackIds = new List<string>();
        for (var i = 0; i < timeline.Tracks.Count; i++)
        {
            var track = timeline.Tracks[i];
            trackIds.Add(track.Id);
            foreach (var clip in track.Clips)
                placements[clip.Id] = new ClipPlacement(track.Id, i, clip.StartFrame, clip.DurationFrames);
        }
        return new TimelineSnapshot(placements, trackIds);
    }

    public static ToolResult Result(
        IAgentEditorHost host,
        TimelineSnapshot before,
        IEnumerable<string>? touched = null,
        Dictionary<string, object?>? extra = null,
        IEnumerable<string>? notes = null)
    {
        var timeline = host.ActiveTimeline;
        if (timeline is null) return ToolResult.Error("No active timeline.");
        var after = Snapshot(timeline);
        var noteList = notes?.ToList() ?? [];
        var changed = new HashSet<string>(
            (touched ?? []).Where(id => after.Placements.ContainsKey(id)));
        foreach (var id in after.Placements.Keys.Where(id => !before.Placements.ContainsKey(id)))
            changed.Add(id);

        var pureShifts = new Dictionary<string, (int From, int Delta)>();
        foreach (var (id, p) in after.Placements)
        {
            if (!before.Placements.TryGetValue(id, out var b) || b.SamePlace(p) || changed.Contains(id))
                continue;
            if (b.TrackId == p.TrackId && b.Duration == p.Duration)
                pureShifts[id] = (b.Start, p.Start - b.Start);
            else
                changed.Add(id);
        }

        var shifts = new List<Dictionary<string, object?>>();
        foreach (var group in pureShifts.Keys.GroupBy(id =>
                     $"{after.Placements[id].Index}|{pureShifts[id].Delta}"))
        {
            var ids = group.ToList();
            if (ids.Count >= ShiftGroupMinimum)
            {
                var first = pureShifts[ids[0]];
                shifts.Add(new Dictionary<string, object?>
                {
                    ["track"] = after.Placements[ids[0]].Index,
                    ["fromFrame"] = ids.Min(id => pureShifts[id].From),
                    ["by"] = first.Delta,
                    ["count"] = ids.Count,
                });
            }
            else
            {
                foreach (var id in ids) changed.Add(id);
            }
        }

        var payload = extra is not null
            ? new Dictionary<string, object?>(extra)
            : new Dictionary<string, object?>();

        var fold = TimelineReceipt.BuildAudioFold(timeline);
        var clips = changed
            .Select(id => ShapeChangedClip(timeline, fold, id))
            .Where(c => c is not null)
            .Cast<Dictionary<string, object?>>()
            .OrderBy(c => (int)c["track"]!)
            .ThenBy(c => ((int[])c["frames"]!)[0])
            .ToList();

        if (clips.Count > ClipLimit)
        {
            payload["clipsNote"] =
                $"Showing {ClipLimit} of {clips.Count} changed clips — re-read get_timeline for the rest.";
            clips = clips.Take(ClipLimit).ToList();
        }
        if (clips.Count > 0) payload["clips"] = clips;
        if (shifts.Count > 0) payload["shifted"] = shifts;

        var removed = before.Placements.Keys.Where(id => !after.Placements.ContainsKey(id)).OrderBy(x => x).ToList();
        if (removed.Count > 0) payload["removedClipIds"] = removed;

        var createdTracks = new List<Dictionary<string, object?>>();
        for (var i = 0; i < after.TrackIds.Count; i++)
        {
            if (before.TrackIds.Contains(after.TrackIds[i])) continue;
            var track = timeline.Tracks[i];
            createdTracks.Add(new Dictionary<string, object?>
            {
                ["index"] = i,
                ["label"] = track.Type == ClipType.Audio ? $"A{i + 1}" : $"V{i + 1}",
                ["type"] = track.Type.ToString().ToLowerInvariant(),
            });
        }
        if (createdTracks.Count > 0) payload["createdTracks"] = createdTracks;

        var afterSet = after.TrackIds.ToHashSet();
        var trackListChanged = before.TrackIds.Any(id => !afterSet.Contains(id))
            || after.TrackIds.Select((id, i) => (id, i)).Any(x =>
            {
                var prev = before.TrackIds.ToList().IndexOf(x.id);
                return prev >= 0 && prev != x.i;
            });
        if (trackListChanged && !payload.ContainsKey("tracks"))
            noteList.Add("Track indices shifted — re-read get_timeline before the next index-based call.");

        if (noteList.Count > 0) payload["notes"] = noteList;
        return ToolResult.OkJson(payload);
    }

    private static Dictionary<string, object?>? ShapeChangedClip(
        Timeline timeline, TimelineReceipt.AudioFold fold, string id)
    {
        for (var t = 0; t < timeline.Tracks.Count; t++)
        {
            var clip = timeline.Tracks[t].Clips.FirstOrDefault(c => c.Id == id);
            if (clip is null) continue;
            return TimelineReceipt.ShapeClip(clip, t, fold, includeTrack: true);
        }
        // Folded audio: return visual host clip
        foreach (var (visualId, partner) in fold.PartnerByVisualId)
        {
            if (partner.Clip.Id != id) continue;
            for (var t = 0; t < timeline.Tracks.Count; t++)
            {
                var visual = timeline.Tracks[t].Clips.FirstOrDefault(c => c.Id == visualId);
                if (visual is null) continue;
                return TimelineReceipt.ShapeClip(visual, t, fold, includeTrack: true);
            }
        }
        return null;
    }
}
