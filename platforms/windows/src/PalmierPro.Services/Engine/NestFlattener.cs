using PalmierPro.Core;
using PalmierPro.Core.Models;

namespace PalmierPro.Services.Engine;

/// Direct port of Preview/NestFlattener.swift: expands one nest carrier level, remapping child
/// clips into parent-timeline frame coordinates. `TimelineSnapshotBuilder` recurses this to
/// flatten arbitrarily deep `.sequence` nesting — see docs/timeline-snapshot-v1.md §4 for the
/// splicing/id/volume-folding rules layered on top by the builder (NOT part of this port).
public static class NestFlattener
{
    public const int MaxDepth = 8;

    public sealed class Flattened
    {
        /// Child visual tracks, child track order preserved (matches Swift's `[[Clip]]`).
        public List<List<Clip>> VideoTracks { get; } = [];
        /// Unmuted child audio tracks; clips within a track never overlap.
        public List<List<Clip>> AudioTracks { get; } = [];
        public int ChildWidth { get; set; }
        public int ChildHeight { get; set; }
    }

    /// `carrier` = the video `.sequence` clip (or its linked audio clip) whose `child` timeline is
    /// being expanded one level. `visual` selects which of the child's lane kinds to flatten.
    public static Flattened Flatten(Clip carrier, Timeline child, bool visual)
    {
        var result = new Flattened { ChildWidth = child.Width, ChildHeight = child.Height };
        int windowStart = carrier.TrimStartFrame;
        int windowEnd = carrier.TrimStartFrame + carrier.DurationFrames;
        int shift = carrier.StartFrame - carrier.TrimStartFrame;

        foreach (var track in child.Tracks)
        {
            if (visual)
            {
                if (track.Type != ClipType.Video || track.Hidden)
                {
                    continue;
                }
                var clips = RemapTrack(track, windowStart, windowEnd, shift, carrier.Id);
                if (clips.Count > 0)
                {
                    result.VideoTracks.Add(clips);
                }
            }
            else
            {
                if (track.Type != ClipType.Audio || track.Muted)
                {
                    continue;
                }
                var clips = RemapTrack(track, windowStart, windowEnd, shift, carrier.Id);
                if (clips.Count > 0)
                {
                    result.AudioTracks.Add(clips);
                }
            }
        }
        return result;
    }

    private static List<Clip> RemapTrack(Track track, int windowStart, int windowEnd, int shift, string nestId)
    {
        var remapped = new List<Clip>();
        foreach (var clip in track.Clips.OrderBy(c => c.StartFrame))
        {
            var mapped = Remap(clip, windowStart, windowEnd, shift, nestId);
            if (mapped is not null)
            {
                remapped.Add(mapped);
            }
        }
        return remapped;
    }

    private static Clip? Remap(Clip clip, int windowStart, int windowEnd, int shift, string nestId)
    {
        int start = Math.Max(clip.StartFrame, windowStart);
        int end = Math.Min(clip.EndFrame, windowEnd);
        if (end <= start)
        {
            return null;
        }

        // Swift's `var c = clip` copies a value type; Clip is a class here, so a real copy is
        // required to avoid mutating the caller's (shared, possibly-nested-multiple-times) clip.
        var c = DeepClone(clip);
        int headCut = start - clip.StartFrame;
        if (headCut > 0)
        {
            c.TrimStartFrame += SwiftMath.RoundToInt(headCut * c.Speed);
            c.FadeInFrames = 0;
            ShiftKeyframeTracks(c, headCut);
        }
        if (end < clip.EndFrame)
        {
            c.FadeOutFrames = 0;
        }
        c.StartFrame = start + shift;
        c.DurationFrames = end - start;
        c.ClampFadesToDuration();
        c.ClampKeyframesToDuration();
        // Unique per nest instance so the same child nested twice can't collide.
        c.Id = $"{nestId}/{clip.Id}";
        return c;
    }

    private static void ShiftKeyframeTracks(Clip clip, int headCut)
    {
        clip.OpacityTrack = clip.OpacityTrack?.Rebased(headCut, clip.Opacity, KeyframeInterpolation.Double);
        clip.VolumeTrack = clip.VolumeTrack?.Rebased(headCut, 0, KeyframeInterpolation.Double);
        clip.PositionTrack = clip.PositionTrack?.Rebased(headCut, new AnimPair(0, 0), KeyframeInterpolation.AnimPair);
        clip.ScaleTrack = clip.ScaleTrack?.Rebased(headCut, new AnimPair(1, 1), KeyframeInterpolation.AnimPair);
        clip.RotationTrack = clip.RotationTrack?.Rebased(headCut, 0, KeyframeInterpolation.Double);
        clip.CropTrack = clip.CropTrack?.Rebased(headCut, clip.Crop, KeyframeInterpolation.Crop);
    }

    /// Round-trips through the existing `ClipJsonConverter` — the same "JSON round-trip stands in
    /// for a value-type copy" pattern `MediaResolver.Snapshot()` already uses in this codebase,
    /// guaranteed to cover every field (including ones added later) without hand-maintaining a
    /// field-by-field copy constructor here.
    private static Clip DeepClone(Clip clip)
    {
        var bytes = System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(clip);
        return System.Text.Json.JsonSerializer.Deserialize<Clip>(bytes)!;
    }
}
