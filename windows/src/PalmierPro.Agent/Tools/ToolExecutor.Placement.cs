using System.Text.Json;
using PalmierPro.Core.Editing;
using PalmierPro.Core.Models;

namespace PalmierPro.Agent.Tools;

public sealed partial class ToolExecutor
{
    private static ToolResult AddClips(IAgentEditorHost host, JsonElement args)
    {
        var ops = host.EditOperations;
        var timeline = host.ActiveTimeline;
        if (ops is null || timeline is null) return ToolResult.Error("Editor is not ready.");
        if (ToolArgs.Array(args, "entries") is not { } entries || entries.GetArrayLength() == 0)
            return ToolResult.Error("Missing or empty 'entries' array");

        var snapshot = MutationDelta.Snapshot(timeline);
        var created = new List<string>();
        var index = 0;
        foreach (var entry in entries.EnumerateArray())
        {
            var mediaRef = ToolArgs.String(entry, "mediaRef");
            if (mediaRef is null)
                return ToolResult.Error($"entries[{index}]: mediaRef is required");

            var start = ToolArgs.Int(entry, "startFrame") ?? 0;
            if (start < 0)
                return ToolResult.Error($"entries[{index}]: startFrame must be >= 0");

            // mediaRef matching a timeline id places a nested Sequence carrier.
            var nested = host.Timelines.FirstOrDefault(t =>
                t.Id == mediaRef
                || t.Id.StartsWith(mediaRef, StringComparison.OrdinalIgnoreCase));
            if (nested is not null && nested.Id != timeline.Id)
            {
                if (ops.WouldCreateNestCycle(nested.Id, timeline.Id,
                        host.Timelines.ToDictionary(t => t.Id, t => t)))
                    return ToolResult.Error($"entries[{index}]: placing timeline would create a nest cycle");

                var trackIndex = ToolArgs.Int(entry, "trackIndex")
                    ?? DefaultTrackIndex(timeline, ClipType.Video);
                if (trackIndex < 0)
                    trackIndex = ops.InsertTrack(timeline.Tracks.Count, ClipType.Video);
                if (trackIndex < 0 || trackIndex >= timeline.Tracks.Count)
                    return ToolResult.Error($"entries[{index}]: track index {trackIndex} out of range");
                if (!ClipType.Sequence.IsCompatible(timeline.Tracks[trackIndex].Type))
                    return ToolResult.Error($"entries[{index}]: sequence incompatible with track");

                var duration = ToolArgs.Int(entry, "endFrame") is { } end
                    ? end - start
                    : Math.Max(1, nested.TotalFrames);
                if (duration < 1)
                    return ToolResult.Error($"entries[{index}]: invalid sequence duration");

                var ids = ops.PlaceClip(new PlaceClipRequest(
                    nested.Id,
                    ClipType.Sequence,
                    nested.TotalFrames / (double)Math.Max(1, nested.Fps),
                    HasAudio: false,
                    trackIndex,
                    start,
                    duration,
                    AddLinkedAudio: false));
                if (ids.Count == 0)
                    return ToolResult.Error($"entries[{index}]: failed to place nested sequence");
                created.AddRange(ids);
                index++;
                continue;
            }

            var asset = host.ResolveMedia(mediaRef);
            if (asset is null)
                return ToolResult.Error($"entries[{index}]: No media with id '{mediaRef}'.");

            var mediaTrackIndex = ToolArgs.Int(entry, "trackIndex");
            if (mediaTrackIndex is null)
            {
                // Mac: omit trackIndex → create/find a compatible track.
                mediaTrackIndex = DefaultTrackIndex(timeline, asset.Type);
                if (mediaTrackIndex < 0)
                    mediaTrackIndex = ops.InsertTrack(
                        timeline.Tracks.Count,
                        asset.Type == ClipType.Audio ? ClipType.Audio : ClipType.Video);
            }
            if (mediaTrackIndex < 0 || mediaTrackIndex >= timeline.Tracks.Count)
                return ToolResult.Error($"entries[{index}]: track index {mediaTrackIndex} out of range");
            if (!asset.Type.IsCompatible(timeline.Tracks[mediaTrackIndex.Value].Type))
                return ToolResult.Error($"entries[{index}]: asset type incompatible with track");

            var (placeDuration, trimStart, trimEnd) = ResolvePlacement(
                asset, timeline.Fps, ToolArgs.Int(entry, "endFrame") is { } endFrame
                    ? endFrame - start
                    : null,
                entry, index);
            if (placeDuration is null)
                return ToolResult.Error($"entries[{index}]: invalid placement (check endFrame/source)");

            var placed = ops.PlaceClip(new PlaceClipRequest(
                asset.Id,
                asset.Type,
                asset.Duration,
                asset.HasAudio ?? asset.Type is ClipType.Video or ClipType.Audio,
                mediaTrackIndex.Value,
                start,
                placeDuration.Value,
                trimStart,
                trimEnd));
            if (placed.Count == 0)
                return ToolResult.Error($"entries[{index}]: failed to place clip");
            created.AddRange(placed);
            index++;
        }

        host.NotifyTimelineChanged();
        return MutationDelta.Result(host, snapshot, created, new Dictionary<string, object?>
        {
            ["createdClipIds"] = created,
        });
    }

    private static ToolResult MoveClips(IAgentEditorHost host, JsonElement args)
    {
        var ops = host.EditOperations;
        if (ops is null) return ToolResult.Error("Editor is not ready.");
        if (ToolArgs.Array(args, "moves") is not { } moves || moves.GetArrayLength() == 0)
            return ToolResult.Error("moves is required");

        var batch = new List<(string ClipId, int ToTrack, int ToFrame)>();
        foreach (var move in moves.EnumerateArray())
        {
            var clipId = ToolArgs.String(move, "clipId");
            if (clipId is null) continue;
            var resolved = ResolveClipIds(host, [clipId]);
            if (resolved.Count == 0) continue;
            if (FindClip(host.ActiveTimeline!, resolved[0]) is not { } clip) continue;
            var found = host.EditOperations!.FindClip(resolved[0]);
            if (found is null) continue;
            var toTrack = ToolArgs.Int(move, "toTrack") ?? found.Value.TrackIndex;
            var toFrame = ToolArgs.Int(move, "toFrame") ?? clip.StartFrame;
            batch.Add((resolved[0], toTrack, toFrame));
        }

        if (batch.Count == 0) return ToolResult.Error("No valid moves.");
        if (!ops.MoveClips(batch))
            return ToolResult.Error("Move refused (compatibility, multicam, or no-op).");
        return ToolResult.OkJson(new { moved = batch.Select(m => m.ClipId).ToList() });
    }

    private static int DefaultTrackIndex(Timeline timeline, ClipType type)
    {
        for (var i = 0; i < timeline.Tracks.Count; i++)
        {
            if (type.IsCompatible(timeline.Tracks[i].Type))
                return i;
        }
        return 0;
    }

    private static (int? Duration, int TrimStart, int TrimEnd) ResolvePlacement(
        MediaManifestEntry asset, int fps, int? durationFrames, JsonElement entry, int index)
    {
        double[]? source = null;
        if (entry.TryGetProperty("source", out var src) && src.ValueKind == JsonValueKind.Array)
        {
            var vals = src.EnumerateArray()
                .Where(e => e.ValueKind == JsonValueKind.Number)
                .Select(e => e.GetDouble())
                .ToArray();
            if (vals.Length == 2) source = vals;
        }

        if (source is not null)
        {
            if (source[1] <= source[0])
                return (null, 0, 0);
            var trimStart = Math.Max(0, (int)Math.Round(source[0] * fps, MidpointRounding.AwayFromZero));
            var duration = TimelineEditOperations.SecondsToFrames(source[1] - source[0], fps);
            var total = Math.Max(0, (int)Math.Round(asset.Duration * fps, MidpointRounding.AwayFromZero));
            var trimEnd = Math.Max(0, total - trimStart - duration);
            return (duration, trimStart, trimEnd);
        }

        if (durationFrames is { } d)
        {
            if (d < 1) return (null, 0, 0);
            return (d, 0, 0);
        }

        if (asset.Duration <= 0)
            return (TimelineEditOperations.SecondsToFrames(5, fps), 0, 0); // stills default
        return (TimelineEditOperations.SecondsToFrames(asset.Duration, fps), 0, 0);
    }
}
