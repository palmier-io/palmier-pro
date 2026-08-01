using System.Text.Json;
using PalmierPro.Core.Models;

namespace PalmierPro.Agent.Tools;

public sealed partial class ToolExecutor
{
    private static ToolResult RemoveClips(IAgentEditorHost host, JsonElement args)
    {
        var ops = host.EditOperations;
        var timeline = host.ActiveTimeline;
        if (ops is null || timeline is null) return ToolResult.Error("Editor is not ready.");
        var ids = ToolArgs.StringArray(args, "clipIds");
        if (ids.Count == 0) return ToolResult.Error("clipIds is required");
        var resolved = ResolveClipIds(host, ids);
        if (resolved.Count == 0) return ToolResult.Error("No matching clips.");

        var snapshot = MutationDelta.Snapshot(timeline);
        var ripple = ToolArgs.Bool(args, "ripple") ?? false;
        if (ripple)
        {
            if (!ops.RippleDeleteClips(resolved))
                return ToolResult.Error("Ripple delete refused (overlap or sync-lock conflict).");
        }
        else
        {
            ops.DeleteClips(resolved);
        }

        host.NotifyTimelineChanged();
        return MutationDelta.Result(host, snapshot, null, new Dictionary<string, object?>
        {
            ["ripple"] = ripple,
        });
    }

    private static ToolResult SplitClips(IAgentEditorHost host, JsonElement args)
    {
        var ops = host.EditOperations;
        var timeline = host.ActiveTimeline;
        if (ops is null || timeline is null) return ToolResult.Error("Editor is not ready.");

        var snapshot = MutationDelta.Snapshot(timeline);
        var created = new List<string>();
        if (ToolArgs.Array(args, "splits") is { } splits)
        {
            foreach (var split in splits.EnumerateArray())
            {
                var clipId = ToolArgs.String(split, "clipId");
                var at = ToolArgs.Int(split, "atFrame");
                if (clipId is null || at is null) continue;
                var resolved = ResolveClipIds(host, [clipId]);
                if (resolved.Count == 0) continue;
                created.AddRange(ops.SplitClip(resolved[0], at.Value));
            }
        }
        else
        {
            var frames = ToolArgs.IntArray(args, "frames");
            var trackIndex = ToolArgs.Int(args, "trackIndex");
            if (frames.Count == 0)
                return ToolResult.Error("Provide splits:[{clipId,atFrame}] or frames with an optional trackIndex.");
            foreach (var frame in frames)
            {
                IEnumerable<Clip> clips = trackIndex is { } ti && ti >= 0 && ti < timeline.Tracks.Count
                    ? timeline.Tracks[ti].Clips
                    : timeline.Tracks.SelectMany(t => t.Clips);
                foreach (var clip in clips.Where(c => frame > c.StartFrame && frame < c.EndFrame).ToList())
                    created.AddRange(ops.SplitClip(clip.Id, frame));
            }
        }

        host.NotifyTimelineChanged();
        return MutationDelta.Result(host, snapshot, created);
    }

    private static ToolResult SetClipProperties(IAgentEditorHost host, JsonElement args)
    {
        var ops = host.EditOperations;
        var timeline = host.ActiveTimeline;
        if (ops is null || timeline is null) return ToolResult.Error("Editor is not ready.");

        var ids = ResolveClipIds(host, ToolArgs.StringArray(args, "clipIds"));
        if (ids.Count == 0) return ToolResult.Error("clipIds is required");

        var opacity = ToolArgs.Number(args, "opacity");
        var volumeDb = ToolArgs.Number(args, "volumeDb");
        var speed = ToolArgs.Number(args, "speed");
        var fadeIn = ToolArgs.Int(args, "fadeInFrames");
        var fadeOut = ToolArgs.Int(args, "fadeOutFrames");
        var edgeRounding = ToolArgs.Number(args, "edgeRounding");
        var edgeSoftness = ToolArgs.Number(args, "edgeSoftness");
        var blendRaw = ToolArgs.String(args, "blendMode");
        var trimStart = ToolArgs.Int(args, "trimStartFrame") ?? ToolArgs.Int(args, "trimStart");
        var trimEnd = ToolArgs.Int(args, "trimEndFrame") ?? ToolArgs.Int(args, "trimEnd");
        var duration = ToolArgs.Int(args, "durationFrames");
        var startFrame = ToolArgs.Int(args, "startFrame");

        BlendMode? blend = null;
        if (blendRaw is not null && Enum.TryParse<BlendMode>(blendRaw, true, out var parsed))
            blend = parsed;

        Transform? transform = null;
        if (args.TryGetProperty("transform", out var tEl) && tEl.ValueKind == JsonValueKind.Object)
        {
            transform = new Transform
            {
                CenterX = ToolArgs.Number(tEl, "centerX") ?? 0.5,
                CenterY = ToolArgs.Number(tEl, "centerY") ?? 0.5,
                Width = ToolArgs.Number(tEl, "width") ?? 1,
                Height = ToolArgs.Number(tEl, "height") ?? 1,
                Rotation = ToolArgs.Number(tEl, "rotation") ?? 0,
                FlipHorizontal = ToolArgs.Bool(tEl, "flipHorizontal") ?? false,
                FlipVertical = ToolArgs.Bool(tEl, "flipVertical") ?? false,
            };
        }

        Crop? crop = null;
        if (args.TryGetProperty("crop", out var cEl) && cEl.ValueKind == JsonValueKind.Object)
        {
            crop = new Crop
            {
                Left = ToolArgs.Number(cEl, "left") ?? 0,
                Top = ToolArgs.Number(cEl, "top") ?? 0,
                Right = ToolArgs.Number(cEl, "right") ?? 0,
                Bottom = ToolArgs.Number(cEl, "bottom") ?? 0,
            };
        }

        var snapshot = MutationDelta.Snapshot(timeline);
        var updated = new List<string>();
        foreach (var id in ids)
        {
            if (FindClip(timeline, id) is null) continue;
            if (opacity is not null) ops.SetClipOpacity(id, opacity.Value);
            if (volumeDb is not null) ops.SetClipVolumeDb(id, volumeDb.Value);
            if (speed is not null) ops.SetClipSpeed(id, speed.Value);
            if (fadeIn is not null) ops.SetClipFade(id, FadeEdge.Left, fadeIn.Value);
            if (fadeOut is not null) ops.SetClipFade(id, FadeEdge.Right, fadeOut.Value);
            if (edgeRounding is not null || edgeSoftness is not null)
                ops.SetClipEdges(id, edgeRounding, edgeSoftness);
            if (blend is not null) ops.SetClipBlendMode(id, blend);
            if (transform is { } tr) ops.SetClipTransform(id, tr);
            if (crop is { } cr) ops.SetClipCrop(id, cr);
            if (trimStart is not null || trimEnd is not null || duration is not null || startFrame is not null)
                ops.SetClipTrimDuration(id, trimStart, trimEnd, duration, startFrame);
            updated.Add(id);
        }

        host.NotifyTimelineChanged();
        return MutationDelta.Result(host, snapshot, updated);
    }

    private static ToolResult ManageTracks(IAgentEditorHost host, JsonElement args)
    {
        var ops = host.EditOperations;
        var timeline = host.ActiveTimeline;
        if (ops is null || timeline is null) return ToolResult.Error("Editor is not ready.");

        var action = (ToolArgs.String(args, "action") ?? "").ToLowerInvariant();
        var trackId = ToolArgs.String(args, "trackId");
        var index = ResolveTrackIndex(timeline, trackId, ToolArgs.Int(args, "index"));
        var snapshot = MutationDelta.Snapshot(timeline);

        switch (action)
        {
            case "add":
            {
                var typeRaw = (ToolArgs.String(args, "type") ?? "video").ToLowerInvariant();
                var type = typeRaw == "audio" ? ClipType.Audio : ClipType.Video;
                var at = ToolArgs.Int(args, "index") ?? timeline.Tracks.Count;
                var created = ops.InsertTrack(at, type);
                host.NotifyTimelineChanged();
                return MutationDelta.Result(host, snapshot, null, new Dictionary<string, object?>
                {
                    ["trackId"] = timeline.Tracks[created].Id,
                    ["index"] = created,
                    ["type"] = type.ToString().ToLowerInvariant(),
                });
            }
            case "remove":
            {
                if (index is null) return ToolResult.Error("trackId or index is required");
                if (!ops.RemoveTracks([index.Value]))
                    return ToolResult.Error("Could not remove track.");
                host.NotifyTimelineChanged();
                return MutationDelta.Result(host, snapshot);
            }
            case "reorder":
            {
                if (index is null) return ToolResult.Error("trackId or index is required");
                var to = ToolArgs.Int(args, "toIndex") ?? ToolArgs.Int(args, "to");
                if (to is null) return ToolResult.Error("toIndex is required for reorder");
                if (!ops.ReorderTrack(index.Value, to.Value))
                    return ToolResult.Error("Reorder refused (partition or identical index).");
                host.NotifyTimelineChanged();
                return MutationDelta.Result(host, snapshot);
            }
            case "set":
            {
                if (index is null) return ToolResult.Error("trackId or index is required");
                if (!ops.SetTrackFlags(
                        index.Value,
                        ToolArgs.Bool(args, "muted"),
                        ToolArgs.Bool(args, "hidden"),
                        ToolArgs.Bool(args, "syncLocked")))
                    return ToolResult.Error("Set track flags refused.");
                break;
            }
            case "mute":
            case "unmute":
            case "togglemute":
                if (index is null) return ToolResult.Error("trackId or index is required");
                ops.ToggleTrackMute(index.Value);
                break;
            case "hide":
            case "show":
            case "togglehidden":
                if (index is null) return ToolResult.Error("trackId or index is required");
                ops.ToggleTrackHidden(index.Value);
                break;
            case "synclock":
            case "togglesynclock":
                if (index is null) return ToolResult.Error("trackId or index is required");
                if (!ops.ToggleTrackSyncLock(index.Value))
                    return ToolResult.Error("Sync-lock toggle refused (multicam track).");
                break;
            default:
                return ToolResult.Error(
                    $"Unsupported manage_tracks action '{action}'. " +
                    "Supported: add, remove, reorder, set, toggleMute, toggleHidden, toggleSyncLock.");
        }

        host.NotifyTimelineChanged();
        var track = timeline.Tracks[index!.Value];
        return MutationDelta.Result(host, snapshot, null, new Dictionary<string, object?>
        {
            ["trackId"] = track.Id,
            ["index"] = index.Value,
            ["muted"] = track.Muted,
            ["hidden"] = track.Hidden,
            ["syncLocked"] = track.SyncLocked,
        });
    }

    private static ToolResult Undo(IAgentEditorHost host, JsonElement args)
    {
        var action = ToolArgs.String(args, "action") ?? "undo";
        if (action == "redo")
        {
            if (!host.UndoManager.CanRedo) return ToolResult.OkJson(new { ok = false, note = "Nothing to redo." });
            host.UndoManager.Redo();
            return ToolResult.OkJson(new { ok = true, action = "redo" });
        }

        if (!host.UndoManager.CanUndo) return ToolResult.OkJson(new { ok = false, note = "Nothing to undo." });
        host.UndoManager.Undo();
        return ToolResult.OkJson(new { ok = true, action = "undo" });
    }

    private static List<string> ResolveClipIds(IAgentEditorHost host, IReadOnlyList<string> ids)
    {
        var timeline = host.ActiveTimeline;
        if (timeline is null) return [];
        var all = timeline.Tracks.SelectMany(t => t.Clips).ToList();
        var resolved = new List<string>();
        foreach (var id in ids)
        {
            var match = all.FirstOrDefault(c => c.Id == id)
                ?? all.FirstOrDefault(c => c.Id.StartsWith(id, StringComparison.OrdinalIgnoreCase));
            if (match is not null && !resolved.Contains(match.Id))
                resolved.Add(match.Id);
        }
        return resolved;
    }

    private static Clip? FindClip(Timeline timeline, string id)
        => timeline.Tracks.SelectMany(t => t.Clips)
            .FirstOrDefault(c => c.Id == id || c.Id.StartsWith(id, StringComparison.OrdinalIgnoreCase));

    private static int? ResolveTrackIndex(Timeline timeline, string? trackId, int? index)
    {
        if (index is { } i && i >= 0 && i < timeline.Tracks.Count) return i;
        if (trackId is null) return null;
        for (var t = 0; t < timeline.Tracks.Count; t++)
        {
            if (timeline.Tracks[t].Id == trackId
                || timeline.Tracks[t].Id.StartsWith(trackId, StringComparison.OrdinalIgnoreCase))
                return t;
        }
        return null;
    }
}
