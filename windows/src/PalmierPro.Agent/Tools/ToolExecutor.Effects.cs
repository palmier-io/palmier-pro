using System.Text.Json;
using PalmierPro.Agent.Skills;
using PalmierPro.Core.Compositing;
using PalmierPro.Core.Editing;
using PalmierPro.Core.Models;
using PalmierPro.Core.Playback;

namespace PalmierPro.Agent.Tools;

public sealed partial class ToolExecutor
{
    private static ToolResult InsertClips(IAgentEditorHost host, JsonElement args)
    {
        var ops = host.EditOperations;
        var timeline = host.ActiveTimeline;
        if (ops is null || timeline is null) return ToolResult.Error("Editor is not ready.");

        var trackIndex = ToolArgs.Int(args, "trackIndex");
        var atFrame = ToolArgs.Int(args, "atFrame");
        if (trackIndex is null || atFrame is null)
            return ToolResult.Error("trackIndex and atFrame are required");
        if (trackIndex < 0 || trackIndex >= timeline.Tracks.Count)
            return ToolResult.Error($"trackIndex {trackIndex} out of range");
        if (atFrame < 0) return ToolResult.Error("atFrame must be >= 0");
        if (ToolArgs.Array(args, "entries") is not { } entries || entries.GetArrayLength() == 0)
            return ToolResult.Error("Missing or empty 'entries' array");

        var specs = new List<Core.Editing.RippleInsertSpec>();
        var index = 0;
        foreach (var entry in entries.EnumerateArray())
        {
            var mediaRef = ToolArgs.String(entry, "mediaRef");
            if (mediaRef is null)
                return ToolResult.Error($"entries[{index}]: mediaRef is required");
            var asset = host.ResolveMedia(mediaRef);
            if (asset is null)
                return ToolResult.Error($"entries[{index}]: No media with id '{mediaRef}'.");
            if (!asset.Type.IsCompatible(timeline.Tracks[trackIndex.Value].Type))
                return ToolResult.Error($"entries[{index}]: incompatible media type");

            var durationFrames = ToolArgs.Int(entry, "durationFrames");
            var (duration, trimStart, trimEnd) = ResolvePlacement(
                asset, timeline.Fps, durationFrames, entry, index);
            if (duration is null)
                return ToolResult.Error($"entries[{index}]: invalid placement");

            specs.Add(new Core.Editing.RippleInsertSpec(
                asset.Id,
                asset.Type,
                asset.Duration,
                asset.HasAudio ?? asset.Type is ClipType.Video or ClipType.Audio,
                duration.Value,
                trimStart,
                trimEnd));
            index++;
        }

        var created = ops.RippleInsertClips(specs, trackIndex.Value, atFrame.Value);
        if (created.Count == 0)
            return ToolResult.Error("Ripple insert refused or produced no clips.");
        return ToolResult.OkJson(new { createdClipIds = created });
    }

    private static ToolResult RippleDeleteRanges(IAgentEditorHost host, JsonElement args)
    {
        var ops = host.EditOperations;
        var timeline = host.ActiveTimeline;
        if (ops is null || timeline is null) return ToolResult.Error("Editor is not ready.");

        var trackIndex = ToolArgs.Int(args, "trackIndex");
        if (trackIndex is null)
        {
            var clipId = ToolArgs.String(args, "clipId");
            if (clipId is null) return ToolResult.Error("trackIndex or clipId is required");
            var found = ops.FindClip(ResolveClipIds(host, [clipId]).FirstOrDefault() ?? "");
            if (found is null) return ToolResult.Error("Clip not found.");
            trackIndex = found.Value.TrackIndex;
        }

        if (ToolArgs.Array(args, "ranges") is not { } rangesEl || rangesEl.GetArrayLength() == 0)
            return ToolResult.Error("ranges is required");

        var ranges = new List<Core.Editing.FrameRange>();
        foreach (var r in rangesEl.EnumerateArray())
        {
            if (r.ValueKind != JsonValueKind.Array || r.GetArrayLength() < 2) continue;
            var a = r[0].ValueKind == JsonValueKind.Number ? r[0].GetInt32() : 0;
            var b = r[1].ValueKind == JsonValueKind.Number ? r[1].GetInt32() : 0;
            if (b > a) ranges.Add(new Core.Editing.FrameRange(a, b));
        }
        if (ranges.Count == 0) return ToolResult.Error("No valid ranges.");
        if (!ops.RippleDeleteRangesOnTrack(trackIndex.Value, ranges))
            return ToolResult.Error("Ripple delete refused (sync-lock collision or invalid range).");
        return ToolResult.OkJson(new { trackIndex = trackIndex.Value, ranges = ranges.Select(r => new[] { r.Start, r.End }) });
    }

    private static ToolResult ApplyEffect(IAgentEditorHost host, JsonElement args)
    {
        var ops = host.EditOperations;
        if (ops is null) return ToolResult.Error("Editor is not ready.");
        var ids = ResolveClipIds(host, ToolArgs.StringArray(args, "clipIds"));
        if (ids.Count == 0) return ToolResult.Error("clipIds is empty.");

        var adds = new List<(string, IReadOnlyDictionary<string, double>?, bool?)>();
        if (ToolArgs.Array(args, "effects") is { } effects)
        {
            foreach (var e in effects.EnumerateArray())
            {
                var type = ToolArgs.String(e, "type");
                if (type is null) continue;
                if (type.StartsWith("color.", StringComparison.Ordinal))
                    return ToolResult.Error($"'{type}' is a color grade — use apply_color.");
                if (EffectRegistry.Descriptor(type) is null)
                    return ToolResult.Error($"Unknown effect '{type}'.");
                Dictionary<string, double>? parameters = null;
                if (e.TryGetProperty("params", out var p) && p.ValueKind == JsonValueKind.Object)
                {
                    parameters = new Dictionary<string, double>();
                    foreach (var prop in p.EnumerateObject())
                    {
                        if (prop.Value.ValueKind == JsonValueKind.Number)
                            parameters[prop.Name] = prop.Value.GetDouble();
                    }
                }
                adds.Add((type, parameters, ToolArgs.Bool(e, "enabled")));
            }
        }
        var remove = ToolArgs.StringArray(args, "remove");
        if (adds.Count == 0 && remove.Count == 0)
            return ToolResult.Error("Provide effects to add/update or remove types to delete.");

        if (!ops.ApplyEffects(ids, adds, remove))
            return ToolResult.Error("apply_effect failed (need video/image clips).");
        return ToolResult.OkJson(new { clipIds = ids });
    }

    private static ToolResult ApplyColor(IAgentEditorHost host, JsonElement args)
    {
        var ops = host.EditOperations;
        if (ops is null) return ToolResult.Error("Editor is not ready.");
        var ids = ResolveClipIds(host, ToolArgs.StringArray(args, "clipIds"));
        if (ids.Count == 0) return ToolResult.Error("clipIds is empty.");

        var reset = ToolArgs.Bool(args, "reset") ?? false;
        var knobs = new Dictionary<string, double>();
        JsonElement source = args;
        if (args.TryGetProperty("color", out var colorObj) && colorObj.ValueKind == JsonValueKind.Object)
            source = colorObj;

        foreach (var key in new[]
                 {
                     "exposure", "contrast", "saturation", "vibrance", "temperature", "tint",
                     "highlights", "shadows", "blacks", "whites",
                 })
        {
            if (ToolArgs.Number(source, key) is { } v)
                knobs[key] = v;
        }

        if (!reset && knobs.Count == 0)
            return ToolResult.Error("Provide color knobs or reset=true.");

        if (!ops.ApplyColorKnobs(ids, knobs, reset))
            return ToolResult.Error("apply_color failed (need video/image clips).");
        return ToolResult.OkJson(new { clipIds = ids, knobs });
    }

    private static ToolResult InspectTimeline(IAgentEditorHost host, JsonElement args)
    {
        var timeline = host.ActiveTimeline;
        if (timeline is null) return ToolResult.Error("No active timeline.");
        var totalFrames = TimelineFrameRouter.DurationFrames(timeline);
        if (totalFrames <= 0) return ToolResult.Error("Timeline is empty — nothing to render.");

        var start = ToolArgs.Int(args, "startFrame") ?? 0;
        if (start < 0 || start >= totalFrames)
            return ToolResult.Error($"startFrame {start} out of range [0, {totalFrames}).");
        var end = ToolArgs.Int(args, "endFrame");
        var maxFrames = Math.Clamp(ToolArgs.Int(args, "maxFrames") ?? 6, 1, 12);

        var frames = new List<int>();
        if (end is null || end <= start) frames.Add(start);
        else
        {
            var span = Math.Min(end.Value, totalFrames) - start;
            if (span <= 0) return ToolResult.Error("endFrame must be greater than startFrame.");
            var count = Math.Clamp(maxFrames, 1, span);
            for (var i = 0; i < count; i++)
            {
                var t = start + (int)Math.Floor((span * (i + 0.5)) / count);
                frames.Add(Math.Clamp(t, start, start + span - 1));
            }
        }

        Timeline? Resolve(string id) => host.Timelines.FirstOrDefault(t => t.Id == id);
        var images = host.RenderTimelineInspectFrames(frames);
        if (images.Count == 0)
            return ToolResult.Error("Failed to render timeline frames.");

        var meta = new
        {
            fps = timeline.Fps,
            width = images[0].Width,
            height = images[0].Height,
            totalFrames,
            frames = images.Select(img =>
            {
                var layers = FrameLayerPlanner.LayersAt(timeline, img.Index, Resolve);
                return new
                {
                    frame = img.Index,
                    clips = layers.Where(l => l.Clip.MediaType.IsVisual())
                        .Select(l => l.Clip.Id).Reverse().ToList(),
                };
            }).ToList(),
        };

        return ToolResult.OkImages(
            images.Select(i => new ToolImageBlock(Convert.ToBase64String(i.Bytes), i.MediaType)),
            meta);
    }

    private static ToolResult ReadSkill(JsonElement args)
    {
        var skillId = ToolArgs.String(args, "skillId");
        if (skillId is null) return ToolResult.Error("skillId is required");
        var body = SkillStore.Shared.ReadBody(skillId);
        if (body is null)
            return ToolResult.Error($"No skill '{skillId}' in {SkillStore.DirectoryPath}.");
        return ToolResult.Ok(body);
    }

    private static ToolResult GetMulticam(IAgentEditorHost host, JsonElement args)
    {
        var groups = host.MulticamGroups;
        var groupId = ToolArgs.String(args, "groupId");
        if (groupId is not null)
        {
            var g = groups.FirstOrDefault(x =>
                x.Id == groupId || x.Id.StartsWith(groupId, StringComparison.OrdinalIgnoreCase));
            if (g is null) return ToolResult.Error($"No multicam group '{groupId}'.");
            return ToolResult.OkJson(GroupDto(g));
        }
        return ToolResult.OkJson(new { groups = groups.Select(GroupDto).ToList() });
    }

    private static ToolResult ChangeCam(IAgentEditorHost host, JsonElement args)
    {
        var ops = host.EditOperations;
        if (ops is null) return ToolResult.Error("Editor is not ready.");

        MulticamSource? ResolveGroup(string? groupId, string? clipId)
        {
            if (groupId is not null)
                return host.MulticamGroups.FirstOrDefault(g =>
                    g.Id == groupId || g.Id.StartsWith(groupId, StringComparison.OrdinalIgnoreCase));
            if (clipId is not null && ops.FindClip(clipId) is { } found
                && found.Clip.MulticamGroupId is { } gid)
                return host.MulticamGroups.FirstOrDefault(g => g.Id == gid);
            return null;
        }

        // Mac shape: entries[{range, angle}]
        if (ToolArgs.Array(args, "entries") is { } entries)
        {
            var group = ResolveGroup(ToolArgs.String(args, "groupId"), ToolArgs.String(args, "clipId"));
            if (group is null) return ToolResult.Error("Multicam group not found.");
            var durations = host.MulticamSourceDurations(group);
            var switched = 0;
            foreach (var entry in entries.EnumerateArray())
            {
                var angle = ToolArgs.String(entry, "angle");
                if (angle is null) continue;
                if (ToolArgs.Array(entry, "range") is { } range && range.GetArrayLength() >= 2)
                {
                    var start = range[0].GetInt32();
                    var end = range[1].GetInt32();
                    if (ops.SwitchMulticamRange(group, start, end, angle, durations))
                        switched++;
                }
            }
            if (switched == 0) return ToolResult.Error("No ranges switched.");
            return ToolResult.OkJson(new { groupId = group.Id, switched });
        }

        // Mac multi-angle overlay: { layout, angles:[...], range? }
        var layoutRaw = ToolArgs.String(args, "layout");
        if (layoutRaw is not null && ToolArgs.Array(args, "angles") is { } anglesEl)
        {
            var group = ResolveGroup(ToolArgs.String(args, "groupId"), ToolArgs.String(args, "clipId"));
            if (group is null) return ToolResult.Error("Multicam group not found.");
            var layout = VideoLayoutExtensions.FromRawValue(layoutRaw);
            if (layout is null) return ToolResult.Error($"Unknown layout '{layoutRaw}'.");
            var angleLabels = anglesEl.EnumerateArray()
                .Where(a => a.ValueKind == JsonValueKind.String)
                .Select(a => a.GetString()!)
                .ToList();
            if (angleLabels.Count == 0) return ToolResult.Error("angles is empty.");
            var start = ToolArgs.Int(args, "startFrame") ?? 0;
            var end = ToolArgs.Int(args, "endFrame")
                ?? start + Math.Max(1, host.ActiveTimeline?.Fps ?? 30);
            if (ToolArgs.Array(args, "range") is { } rangeArr && rangeArr.GetArrayLength() >= 2)
            {
                start = rangeArr[0].GetInt32();
                end = rangeArr[1].GetInt32();
            }
            var placed = ApplyMulticamLayout(host, ops, group, layout.Value, angleLabels, start, end);
            if (placed.Count == 0) return ToolResult.Error("Could not place multicam layout.");
            return ToolResult.OkJson(new
            {
                groupId = group.Id,
                layout = layout.Value.RawValue(),
                angles = angleLabels,
                createdClipIds = placed,
            });
        }

        var angleLabel = ToolArgs.String(args, "angle");
        if (angleLabel is null) return ToolResult.Error("angle, entries, or layout+angles is required");
        var clipIds = ResolveClipIds(host, ToolArgs.StringArray(args, "clipIds"));
        var g2 = ResolveGroup(ToolArgs.String(args, "groupId"), clipIds.FirstOrDefault());
        if (g2 is null) return ToolResult.Error("Multicam group not found.");
        var durs = host.MulticamSourceDurations(g2);
        var count = 0;
        if (clipIds.Count > 0)
        {
            foreach (var id in clipIds)
            {
                if (ops.SwitchMulticamSegment(id, angleLabel, g2, durs)) count++;
            }
        }
        else if (ToolArgs.Int(args, "startFrame") is { } rs && ToolArgs.Int(args, "endFrame") is { } re)
        {
            if (ops.SwitchMulticamRange(g2, rs, re, angleLabel, durs)) count++;
        }
        else return ToolResult.Error("Provide clipIds, startFrame/endFrame, or entries[].");

        if (count == 0) return ToolResult.Error("No clips switched.");
        return ToolResult.OkJson(new { groupId = g2.Id, angle = angleLabel, switched = count });
    }

    private static List<string> ApplyMulticamLayout(
        IAgentEditorHost host,
        TimelineEditOperations ops,
        MulticamSource group,
        VideoLayout layout,
        IReadOnlyList<string> angleLabels,
        int startFrame,
        int endFrame)
    {
        var timeline = host.ActiveTimeline;
        if (timeline is null || endFrame <= startFrame) return [];
        var slots = layout.Slots().OrderBy(s => s.Z).ToList();
        var created = new List<string>();
        var clipIdsBySlot = new Dictionary<string, IReadOnlyList<string>>();

        for (var i = 0; i < Math.Min(slots.Count, angleLabels.Count); i++)
        {
            var member = group.MemberLabeled(angleLabels[i]);
            if (member is null) continue;
            var entry = host.ResolveMedia(member.MediaRef);
            if (entry is null) continue;
            var track = ops.InsertTrack(0, ClipType.Video);
            var ids = ops.PlaceClip(new PlaceClipRequest(
                entry.Id, entry.Type, entry.Duration,
                entry.HasAudio ?? false, track, startFrame,
                endFrame - startFrame, AddLinkedAudio: false));
            if (ids.Count == 0) continue;
            foreach (var id in ids)
            {
                if (ops.FindClip(id) is { } found)
                    found.Clip.MulticamGroupId = group.Id;
            }
            created.AddRange(ids);
            clipIdsBySlot[slots[i].Id] = [ids[0]];
        }

        if (clipIdsBySlot.Count == 0) return [];
        ops.ApplyLayoutToClips(layout, LayoutFit.Fill, clipIdsBySlot, _ => null);
        host.NotifyTimelineChanged();
        return created;
    }

    private static ToolResult ManageMulticam(IAgentEditorHost host, JsonElement args)
    {
        var ops = host.EditOperations;
        if (ops is null) return ToolResult.Error("Editor is not ready.");

        // Mac: { create: {...} } or { ungroup: { groupId } } — also accept action=ungroup.
        var wantsUngroup = args.TryGetProperty("ungroup", out var ungroupObj)
            || string.Equals(ToolArgs.String(args, "action"), "ungroup", StringComparison.OrdinalIgnoreCase)
            || string.Equals(ToolArgs.String(args, "action"), "dissolve", StringComparison.OrdinalIgnoreCase);
        if (wantsUngroup)
        {
            var groupId = ungroupObj.ValueKind == JsonValueKind.Object
                ? ToolArgs.String(ungroupObj, "groupId")
                : ToolArgs.String(args, "groupId");
            if (groupId is null) return ToolResult.Error("groupId is required");
            var group = host.MulticamGroups.FirstOrDefault(g =>
                g.Id == groupId || g.Id.StartsWith(groupId, StringComparison.OrdinalIgnoreCase));
            if (group is null) return ToolResult.Error($"No multicam group '{groupId}'.");
            if (!ops.UngroupMulticam(group.Id))
                return ToolResult.Error("Ungroup failed.");
            host.RemoveMulticamGroup(group.Id);
            return ToolResult.OkJson(new { ungrouped = group.Id });
        }

        JsonElement createArgs = args;
        if (args.TryGetProperty("create", out var createObj) && createObj.ValueKind == JsonValueKind.Object)
            createArgs = createObj;
        else if (!args.TryGetProperty("members", out _)
                 && !string.Equals(ToolArgs.String(args, "action"), "create", StringComparison.OrdinalIgnoreCase))
            return ToolResult.Error("manage_multicam requires create or ungroup.");

        var membersEl = ToolArgs.Array(createArgs, "members");
        if (membersEl is null || membersEl.Value.GetArrayLength() < 2)
            return ToolResult.Error("create.members needs at least 2 entries.");

        var groupName = ToolArgs.String(createArgs, "name") ?? "Multicam";
        var startFrame = ToolArgs.Int(createArgs, "startFrame") ?? 0;
        var members = new List<MulticamSource.Member>();
        var angleIndex = 1;
        foreach (var m in membersEl.Value.EnumerateArray())
        {
            var mediaRef = ToolArgs.String(m, "mediaRef");
            if (mediaRef is null) continue;
            var asset = host.ResolveMedia(mediaRef);
            if (asset is null) return ToolResult.Error($"No media '{mediaRef}'.");
            var kindRaw = (ToolArgs.String(m, "kind") ?? "angle").ToLowerInvariant();
            var kind = kindRaw switch
            {
                "mic" => MulticamSource.MemberKind.Mic,
                "both" => MulticamSource.MemberKind.Both,
                _ => MulticamSource.MemberKind.Angle,
            };
            var label = ToolArgs.String(m, "angleLabel")
                        ?? (kind == MulticamSource.MemberKind.Mic ? $"Mic {angleIndex}" : $"Cam {angleIndex}");
            var offset = ToolArgs.Number(m, "offsetSeconds") ?? 0;
            members.Add(new MulticamSource.Member
            {
                MediaRef = asset.Id,
                Kind = kind,
                AngleLabel = label,
                Sync = new MulticamSource.SyncMap
                {
                    OffsetSeconds = offset,
                    Confidence = 1,
                    Locked = true,
                },
            });
            angleIndex++;
        }
        if (members.Count < 2) return ToolResult.Error("Need at least 2 valid members.");

        var source = new MulticamSource
        {
            Name = groupName,
            Members = members,
            MasterMemberId = members[0].Id,
        };
        host.AddMulticamGroup(source);

        // Place program cut from master angle.
        var master = source.Master ?? members[0];
        var assetEntry = host.ResolveMedia(master.MediaRef);
        var fps = Math.Max(1, host.ActiveTimeline?.Fps ?? 30);
        var durationFrames = Math.Max(1, (int)Math.Round((assetEntry?.Duration ?? 5) * fps));
        var placed = ops.PlaceClip(new PlaceClipRequest(
            MediaRef: master.MediaRef,
            MediaType: ClipType.Video,
            DurationSeconds: assetEntry?.Duration ?? 5,
            HasAudio: assetEntry?.HasAudio ?? false,
            TrackIndex: 0,
            StartFrame: startFrame,
            DurationFrames: durationFrames,
            AddLinkedAudio: false));
        foreach (var id in placed)
        {
            if (ops.FindClip(id) is { } found)
                found.Clip.MulticamGroupId = source.Id;
        }

        host.NotifyTimelineChanged();
        return ToolResult.OkJson(new
        {
            created = new
            {
                groupId = source.Id,
                members = members.Select(m => new
                {
                    angleLabel = m.AngleLabel,
                    kind = m.Kind.ToString().ToLowerInvariant(),
                    mediaRef = m.MediaRef,
                    offsetSeconds = m.Sync.OffsetSeconds,
                    confidence = m.Sync.Confidence,
                }).ToList(),
                clipIds = placed,
            },
        });
    }

    private static object GroupDto(MulticamSource g) => new
    {
        groupId = g.Id,
        name = g.Name,
        angles = g.Angles.Select(m => m.AngleLabel).ToList(),
        mics = g.Mics.Select(m => m.AngleLabel).ToList(),
    };
}
