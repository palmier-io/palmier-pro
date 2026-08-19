using PalmierPro.Core.Models;
using PalmierPro.Core.Serialization;

namespace PalmierPro.Core.Editing;

public sealed partial class TimelineEditOperations
{
    /// <summary>
    /// Creates a nested timeline from selected clips and replaces them with a sequence carrier.
    /// Returns (nestedTimeline, carrierClipId) or null on refusal.
    /// </summary>
    public (Timeline Nested, string CarrierClipId)? NestClips(
        IReadOnlyCollection<string> clipIds,
        string? name,
        Func<Timeline, string> registerTimeline)
    {
        var located = clipIds
            .Select(id => FindClip(id))
            .Where(f => f is not null)
            .Select(f => f!.Value)
            .OrderBy(f => f.TrackIndex)
            .ThenBy(f => f.Clip.StartFrame)
            .ToList();
        if (located.Count == 0) return null;

        var minStart = located.Min(l => l.Clip.StartFrame);
        var maxEnd = located.Max(l => l.Clip.EndFrame);
        var duration = Math.Max(1, maxEnd - minStart);
        var minTrack = located.Min(l => l.TrackIndex);
        var maxTrack = located.Max(l => l.TrackIndex);

        var nested = new Timeline
        {
            Name = name ?? "Nested Sequence",
            Fps = Timeline.Fps,
            Width = Timeline.Width,
            Height = Timeline.Height,
            Tracks = [],
        };
        for (var t = minTrack; t <= maxTrack; t++)
        {
            nested.Tracks.Add(new Track { Type = Timeline.Tracks[t].Type });
        }

        foreach (var (trackIndex, clip) in located)
        {
            var clone = Clone(clip);
            clone.Id = Uuid.NewString();
            clone.StartFrame = clip.StartFrame - minStart;
            clone.MulticamGroupId = null;
            nested.Tracks[trackIndex - minTrack].Clips.Add(clone);
        }

        var nestedId = registerTimeline(nested);
        string? carrierId = null;
        MutateWithTimelineSwap("Nest Clips", () =>
        {
            foreach (var (trackIndex, clip) in located)
                Timeline.Tracks[trackIndex].Clips.Remove(clip);

            var carrier = new Clip
            {
                MediaRef = nestedId,
                MediaType = ClipType.Sequence,
                SourceClipType = ClipType.Sequence,
                StartFrame = minStart,
                DurationFrames = duration,
            };
            ClearRegion(minTrack, minStart, maxEnd);
            Timeline.Tracks[minTrack].Clips.Add(carrier);
            SortAllTracks();
            carrierId = carrier.Id;
        });

        return carrierId is null ? null : (nested, carrierId);
    }

    public bool WouldCreateNestCycle(string nestedTimelineId, string intoTimelineId, IReadOnlyDictionary<string, Timeline> all)
    {
        if (nestedTimelineId == intoTimelineId) return true;
        if (!all.TryGetValue(nestedTimelineId, out var nested)) return false;
        foreach (var clip in nested.Tracks.SelectMany(t => t.Clips))
        {
            if (clip.MediaType != ClipType.Sequence) continue;
            if (clip.MediaRef == intoTimelineId) return true;
            if (WouldCreateNestCycle(clip.MediaRef, intoTimelineId, all)) return true;
        }
        return false;
    }

    /// <summary>Replace a sequence carrier with its nested timeline contents (one level).</summary>
    public bool UnnestClip(string carrierClipId, IReadOnlyDictionary<string, Timeline> all)
    {
        if (FindClip(carrierClipId) is not { } found) return false;
        if (found.Clip.MediaType != ClipType.Sequence) return false;
        if (!all.TryGetValue(found.Clip.MediaRef, out var nested)) return false;

        MutateWithTimelineSwap("Unnest", () =>
        {
            var originTrack = found.TrackIndex;
            var originStart = found.Clip.StartFrame;
            Timeline.Tracks[originTrack].Clips.Remove(found.Clip);

            // Ensure enough tracks exist of compatible types.
            for (var t = 0; t < nested.Tracks.Count; t++)
            {
                var needType = nested.Tracks[t].Type;
                var dest = originTrack + t;
                while (dest >= Timeline.Tracks.Count
                       || !needType.IsCompatible(Timeline.Tracks[dest].Type))
                {
                    InsertTrackRaw(Math.Min(dest, Timeline.Tracks.Count), needType);
                }
                foreach (var clip in nested.Tracks[t].Clips)
                {
                    var clone = Clone(clip);
                    clone.Id = Uuid.NewString();
                    clone.StartFrame = originStart + clip.StartFrame;
                    ClearRegion(dest, clone.StartFrame, clone.EndFrame);
                    Timeline.Tracks[dest].Clips.Add(clone);
                }
            }
            SortAllTracks();
        });
        return true;
    }
}
