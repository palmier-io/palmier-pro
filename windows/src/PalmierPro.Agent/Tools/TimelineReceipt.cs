using System.Text.Json;
using PalmierPro.Core.Models;

namespace PalmierPro.Agent.Tools;

/// <summary>Mac-shaped get_timeline compaction: frames, audio fold, gaps, captionGroups.</summary>
internal static class TimelineReceipt
{
    public static Dictionary<string, object?> Build(
        IAgentEditorHost host,
        int? startFrame,
        int? endFrame,
        bool captionDetail)
    {
        var timeline = host.ActiveTimeline
            ?? throw new InvalidOperationException("No active timeline.");
        var fold = BuildAudioFold(timeline);
        var tracks = new List<object>();
        for (var i = 0; i < timeline.Tracks.Count; i++)
        {
            var track = timeline.Tracks[i];
            var shaped = ShapeTrack(track, i, fold, startFrame, endFrame, captionDetail);
            tracks.Add(shaped);
        }

        var payload = new Dictionary<string, object?>
        {
            ["id"] = timeline.Id,
            ["name"] = timeline.Name,
            ["fps"] = timeline.Fps,
            ["width"] = timeline.Width,
            ["height"] = timeline.Height,
            ["totalFrames"] = timeline.TotalFrames,
            ["durationSeconds"] = timeline.TotalFrames / (double)Math.Max(1, timeline.Fps),
            ["currentFrame"] = host.CurrentFrame,
            ["canGenerate"] = host.CanGenerate,
            ["tracks"] = tracks,
        };
        if (startFrame is not null || endFrame is not null)
        {
            payload["window"] = new[]
            {
                startFrame ?? 0,
                Math.Min(endFrame ?? timeline.TotalFrames, timeline.TotalFrames),
            };
        }

        var groups = host.MulticamGroups;
        if (groups.Count > 0)
        {
            payload["multicamGroups"] = groups.Select(g => new Dictionary<string, object?>
            {
                ["groupId"] = g.Id,
                ["name"] = g.Name,
                ["angles"] = g.Angles.Select(a => a.AngleLabel).ToList(),
                ["mics"] = g.Mics.Select(m => m.AngleLabel).ToList(),
            }).ToList();
        }

        if (host.Timelines.Count > 1)
        {
            payload["timelines"] = host.Timelines.Select(t => new Dictionary<string, object?>
            {
                ["timelineId"] = t.Id,
                ["name"] = t.Name,
                ["active"] = t.Id == host.ActiveTimelineId ? true : null,
            }).ToList();
        }

        return payload;
    }

    public static Dictionary<string, object?> ShapeClip(
        Clip clip, int trackIndex, AudioFold fold, bool includeTrack = false)
    {
        var d = new Dictionary<string, object?>
        {
            ["id"] = clip.Id,
            ["mediaRef"] = clip.MediaRef,
            ["frames"] = new[] { clip.StartFrame, clip.EndFrame },
        };
        if (includeTrack) d["track"] = trackIndex;
        if (clip.MediaType != ClipType.Video)
            d["mediaType"] = clip.MediaType.ToString().ToLowerInvariant();
        if (clip.MediaType != ClipType.Text)
        {
            if (clip.TrimStartFrame != 0) d["trimStartFrame"] = clip.TrimStartFrame;
            if (clip.TrimEndFrame != 0) d["trimEndFrame"] = clip.TrimEndFrame;
        }
        if (Math.Abs(clip.Speed - 1.0) > 1e-9) d["speed"] = Math.Round(clip.Speed, 3);
        if (Math.Abs(clip.Opacity - 1.0) > 1e-9) d["opacity"] = Math.Round(clip.Opacity, 3);
        var volumeDb = VolumeScale.DbFromLinear(clip.Volume);
        if (Math.Abs(volumeDb) > 0.05) d["volumeDb"] = Math.Round(volumeDb, 3);
        if (clip.FadeInFrames != 0) d["fadeInFrames"] = clip.FadeInFrames;
        if (clip.FadeOutFrames != 0) d["fadeOutFrames"] = clip.FadeOutFrames;
        if (clip.EdgeRounding > 1e-6) d["edgeRounding"] = Math.Round(clip.EdgeRounding, 3);
        if (clip.EdgeSoftness > 1e-6) d["edgeSoftness"] = Math.Round(clip.EdgeSoftness, 3);
        if (clip.BlendMode is { } blend && blend != BlendMode.Normal)
            d["blendMode"] = blend.ToString().ToLowerInvariant();
        if (clip.CaptionGroupId is not null) d["captionGroupId"] = clip.CaptionGroupId;
        if (clip.MulticamGroupId is not null) d["multicamGroupId"] = clip.MulticamGroupId;
        if (clip.TextContent is not null) d["textContent"] = clip.TextContent;
        if (clip.TextStyle is { } style)
            d["textStyle"] = TextStyleDict(style);
        if (!IsIdentityTransform(clip.Transform))
            d["transform"] = TransformDict(clip.Transform);
        if (!IsIdentityCrop(clip.Crop))
            d["crop"] = CropDict(clip.Crop);

        var color = ColorFromEffects(clip);
        if (color.Count > 0) d["color"] = color;
        var effects = NonColorEffects(clip);
        if (effects.Count > 0) d["effects"] = effects;
        var keyframes = KeyframesDict(clip);
        if (keyframes.Count > 0) d["keyframes"] = keyframes;

        if (fold.PartnerByVisualId.TryGetValue(clip.Id, out var partner))
        {
            d["audio"] = AudioSummary(partner.Clip, partner.TrackIndex, clip);
        }
        else if (clip.LinkGroupId is not null && !fold.FoldedAudioIds.Contains(clip.Id))
        {
            d["linkGroupId"] = clip.LinkGroupId;
        }

        return d;
    }

    public sealed record AudioFold(
        Dictionary<string, (Clip Clip, int TrackIndex)> PartnerByVisualId,
        HashSet<string> FoldedAudioIds,
        Dictionary<int, int> LinkedCountByTrack);

    public static AudioFold BuildAudioFold(Timeline timeline)
    {
        var byGroup = new Dictionary<string, List<(Clip Clip, int TrackIndex)>>();
        for (var t = 0; t < timeline.Tracks.Count; t++)
        {
            foreach (var clip in timeline.Tracks[t].Clips)
            {
                if (clip.LinkGroupId is null) continue;
                if (!byGroup.TryGetValue(clip.LinkGroupId, out var list))
                    byGroup[clip.LinkGroupId] = list = [];
                list.Add((clip, t));
            }
        }

        var partners = new Dictionary<string, (Clip, int)>();
        var foldedAudio = new HashSet<string>();
        var linkedCounts = new Dictionary<int, int>();
        foreach (var members in byGroup.Values)
        {
            if (members.Count != 2) continue;
            var audio = members.FirstOrDefault(m => m.Clip.MediaType == ClipType.Audio);
            var visual = members.FirstOrDefault(m => m.Clip.MediaType != ClipType.Audio);
            if (audio.Clip is null || visual.Clip is null) continue;
            partners[visual.Clip.Id] = audio;
            foldedAudio.Add(audio.Clip.Id);
            linkedCounts[audio.TrackIndex] = linkedCounts.GetValueOrDefault(audio.TrackIndex) + 1;
        }
        return new AudioFold(partners, foldedAudio, linkedCounts);
    }

    private static readonly HashSet<string> CaptionRowKeys =
        ["id", "frames", "textContent", "captionGroupId", "wordTimings"];

    private static Dictionary<string, object?> ShapeTrack(
        Track track, int index, AudioFold fold, int? start, int? end, bool captionDetail)
    {
        var loose = new List<Dictionary<string, object?>>();
        var groupOrder = new List<string>();
        var grouped = new Dictionary<string, List<Dictionary<string, object?>>>();
        var skippedWindow = 0;
        foreach (var clip in track.Clips)
        {
            if (fold.FoldedAudioIds.Contains(clip.Id)) continue;
            if (!InWindow(clip, start, end) && clip.CaptionGroupId is null)
            {
                skippedWindow++;
                continue;
            }
            var shaped = ShapeClip(clip, index, fold);
            if (clip.CaptionGroupId is { } gid)
            {
                if (!grouped.ContainsKey(gid)) groupOrder.Add(gid);
                if (!grouped.TryGetValue(gid, out var list))
                    grouped[gid] = list = [];
                list.Add(shaped);
                continue;
            }
            if (!InWindow(clip, start, end)) { skippedWindow++; continue; }
            loose.Add(shaped);
        }

        var groups = new List<Dictionary<string, object?>>();
        foreach (var gid in groupOrder)
        {
            var (group, deviants) = CaptionGroup(gid, grouped[gid], start, end, captionDetail);
            groups.Add(group);
            loose.AddRange(deviants);
        }
        loose.Sort((a, b) => FrameStart(a).CompareTo(FrameStart(b)));
        var visible = start is null && end is null
            ? loose
            : loose.Where(c => ClipIntersects(c, start ?? 0, end ?? int.MaxValue)).ToList();

        var d = new Dictionary<string, object?>
        {
            ["trackId"] = track.Id,
            ["index"] = index,
            ["label"] = TrackLabel(track, index),
            ["type"] = track.Type.ToString().ToLowerInvariant(),
        };
        if (track.Muted) d["muted"] = true;
        if (track.Hidden) d["hidden"] = true;
        if (!track.SyncLocked) d["syncLocked"] = false;
        if (visible.Count > 0) d["clips"] = visible;
        if (groups.Count > 0) d["captionGroups"] = groups;
        var gaps = TrackGaps(track);
        if (gaps.Count > 0) d["gaps"] = gaps;
        if (fold.LinkedCountByTrack.TryGetValue(index, out var linked) && linked > 0)
            d["linkedClips"] = linked;
        if (visible.Count < loose.Count || skippedWindow > 0)
            d["totalClips"] = track.Clips.Count;
        return d;
    }

    /// <summary>
    /// Mac captionGroup: modal residual style becomes shared; style-deviant members stay as loose clips.
    /// </summary>
    private static (Dictionary<string, object?> Group, List<Dictionary<string, object?>> Deviants) CaptionGroup(
        string groupId,
        List<Dictionary<string, object?>> members,
        int? windowStart,
        int? windowEnd,
        bool detail)
    {
        var counts = new Dictionary<string, int>();
        var modalKey = "";
        Dictionary<string, object?> shared = new();
        var entries = new List<(Dictionary<string, object?> Clip, string Key)>();
        foreach (var clip in members)
        {
            var residual = clip
                .Where(kv => !CaptionRowKeys.Contains(kv.Key))
                .ToDictionary(kv => kv.Key, kv => kv.Value);
            if (residual.TryGetValue("transform", out var tObj) && tObj is Dictionary<string, object?> t)
            {
                t.Remove("width");
                t.Remove("height");
                t.Remove("flipHorizontal");
                t.Remove("flipVertical");
                if (t.Count == 0) residual.Remove("transform");
                else residual["transform"] = t;
            }
            var key = CanonicalJson(residual);
            counts[key] = counts.GetValueOrDefault(key) + 1;
            if (counts[key] > counts.GetValueOrDefault(modalKey))
            {
                modalKey = key;
                shared = residual;
            }
            entries.Add((clip, key));
        }

        var rows = new List<object[]>();
        var deviants = new List<Dictionary<string, object?>>();
        var frameMin = int.MaxValue;
        var frameMax = 0;
        foreach (var (clip, key) in entries)
        {
            var start = FrameStart(clip);
            var end = FrameEnd(clip);
            frameMin = Math.Min(frameMin, start);
            frameMax = Math.Max(frameMax, end);
            if (key == modalKey)
                rows.Add([clip.GetValueOrDefault("id") ?? "", start, end, clip.GetValueOrDefault("textContent") ?? ""]);
            else
                deviants.Add(clip);
        }

        var total = rows.Count;
        if (windowStart is not null || windowEnd is not null)
        {
            var ws = windowStart ?? 0;
            var we = windowEnd ?? int.MaxValue;
            rows = rows.Where(r => (int)r[1] < we && (int)r[2] > ws).ToList();
        }
        rows.Sort((a, b) => ((int)a[1]).CompareTo((int)b[1]));

        var group = new Dictionary<string, object?>
        {
            ["captionGroupId"] = groupId,
            ["clipCount"] = total,
            ["frameRange"] = new[] { frameMin == int.MaxValue ? 0 : frameMin, frameMax },
        };
        if (shared.Count > 0) group["shared"] = shared;

        if (!detail)
        {
            if (rows.Count > 0)
            {
                var first = rows[0][3]?.ToString() ?? "";
                var last = rows[^1][3]?.ToString() ?? "";
                group["textPreview"] = rows.Count == 1
                    ? TruncatePreview(first)
                    : $"{TruncatePreview(first)} … {TruncatePreview(last)}";
            }
            group["clipsNote"] =
                "Per-clip rows omitted — re-read with captionDetail:true; get_transcript has the spoken words.";
            return (group, deviants);
        }

        var shown = rows.Take(200).ToList();
        group["clipFormat"] = new[] { "clipId", "startFrame", "endFrame", "text" };
        group["clips"] = shown;
        if (shown.Count < total)
            group["clipsNote"] = $"Showing {shown.Count} of {total} caption clips. Page with startFrame/endFrame.";
        return (group, deviants);
    }

    private static string TruncatePreview(string text)
        => text.Length > 60 ? text[..60] + "…" : text;

    private static int FrameStart(Dictionary<string, object?> clip)
        => clip.TryGetValue("frames", out var f) && f is int[] a && a.Length > 0 ? a[0] : 0;

    private static int FrameEnd(Dictionary<string, object?> clip)
        => clip.TryGetValue("frames", out var f) && f is int[] a && a.Length > 1 ? a[1] : 0;

    private static bool ClipIntersects(Dictionary<string, object?> clip, int start, int end)
        => FrameStart(clip) < end && FrameEnd(clip) > start;

    private static string CanonicalJson(Dictionary<string, object?> dict)
    {
        var sorted = SortKeys(dict);
        return JsonSerializer.Serialize(sorted);
    }

    private static object? SortKeys(object? value) => value switch
    {
        Dictionary<string, object?> d => d.OrderBy(kv => kv.Key, StringComparer.Ordinal)
            .ToDictionary(kv => kv.Key, kv => SortKeys(kv.Value)),
        IEnumerable<object?> list when value is not string => list.Select(SortKeys).ToList(),
        _ => value,
    };

    private static List<int[]> TrackGaps(Track track)
    {
        var spans = track.Clips
            .Where(c => c.CaptionGroupId is null)
            .Select(c => new[] { c.StartFrame, c.EndFrame })
            .OrderBy(s => s[0])
            .ToList();
        var gaps = new List<int[]>();
        var maxEnd = 0;
        var first = true;
        foreach (var span in spans)
        {
            if (!first && span[0] > maxEnd)
                gaps.Add([maxEnd, span[0]]);
            maxEnd = Math.Max(maxEnd, span[1]);
            first = false;
        }
        return gaps;
    }

    private static Dictionary<string, object?> AudioSummary(Clip audio, int trackIndex, Clip visual)
    {
        var d = new Dictionary<string, object?>
        {
            ["id"] = audio.Id,
            ["track"] = trackIndex,
        };
        if (audio.StartFrame != visual.StartFrame || audio.DurationFrames != visual.DurationFrames)
            d["frames"] = new[] { audio.StartFrame, audio.EndFrame };
        if (audio.TrimStartFrame != visual.TrimStartFrame) d["trimStartFrame"] = audio.TrimStartFrame;
        if (audio.TrimEndFrame != visual.TrimEndFrame) d["trimEndFrame"] = audio.TrimEndFrame;
        if (Math.Abs(audio.Speed - visual.Speed) > 1e-9) d["speed"] = Math.Round(audio.Speed, 3);
        var volumeDb = VolumeScale.DbFromLinear(audio.Volume);
        if (Math.Abs(volumeDb) > 0.05) d["volumeDb"] = Math.Round(volumeDb, 3);
        if (audio.FadeInFrames != 0) d["fadeInFrames"] = audio.FadeInFrames;
        if (audio.FadeOutFrames != 0) d["fadeOutFrames"] = audio.FadeOutFrames;
        var effects = NonColorEffects(audio);
        if (effects.Count > 0) d["effects"] = effects;
        return d;
    }

    private static Dictionary<string, object?> ColorFromEffects(Clip clip)
    {
        var color = new Dictionary<string, object?>();
        if (clip.Effects is null) return color;
        foreach (var e in clip.Effects.Where(x => x.Type.StartsWith("color.", StringComparison.Ordinal)))
        {
            var key = e.Type["color.".Length..];
            color[key] = e.Params.ToDictionary(
                kv => kv.Key,
                kv => (object?)(kv.Value.Value ?? (object?)kv.Value.String));
        }
        return color;
    }

    private static List<Dictionary<string, object?>> NonColorEffects(Clip clip)
    {
        if (clip.Effects is null) return [];
        return clip.Effects
            .Where(e => !e.Type.StartsWith("color.", StringComparison.Ordinal))
            .Select(e =>
            {
                var d = new Dictionary<string, object?> { ["type"] = e.Type };
                if (!e.Enabled) d["enabled"] = false;
                if (e.Params.Count > 0)
                {
                    d["params"] = e.Params.ToDictionary(
                        kv => kv.Key,
                        kv => (object?)(kv.Value.Value ?? (object?)kv.Value.String));
                }
                return d;
            }).ToList();
    }

    private static Dictionary<string, object?> KeyframesDict(Clip clip)
    {
        var d = new Dictionary<string, object?>();
        if (clip.OpacityTrack is { IsActive: true } op)
            d["opacity"] = op.Keyframes.Select(k => new object[] { k.Frame, Math.Round(k.Value, 3) }).ToList();
        if (clip.RotationTrack is { IsActive: true } rot)
            d["rotation"] = rot.Keyframes.Select(k => new object[] { k.Frame, Math.Round(k.Value, 3) }).ToList();
        if (clip.VolumeTrack is { IsActive: true } vol)
            d["volumeDb"] = vol.Keyframes.Select(k => new object[] { k.Frame, Math.Round(k.Value, 3) }).ToList();
        if (clip.PositionTrack is { IsActive: true } pos)
            d["position"] = pos.Keyframes.Select(k => new object[]
            {
                k.Frame, Math.Round(k.Value.A, 3), Math.Round(k.Value.B, 3),
            }).ToList();
        if (clip.ScaleTrack is { IsActive: true } sc)
            d["scale"] = sc.Keyframes.Select(k => new object[]
            {
                k.Frame, Math.Round(k.Value.A, 3), Math.Round(k.Value.B, 3),
            }).ToList();
        if (clip.CropTrack is { IsActive: true } crop)
            d["crop"] = crop.Keyframes.Select(k => new object[]
            {
                k.Frame,
                Math.Round(k.Value.Left, 3), Math.Round(k.Value.Top, 3),
                Math.Round(k.Value.Right, 3), Math.Round(k.Value.Bottom, 3),
            }).ToList();
        return d;
    }

    private static bool InWindow(Clip clip, int? start, int? end)
    {
        if (start is null && end is null) return true;
        var s = start ?? 0;
        var e = end ?? int.MaxValue;
        return clip.StartFrame < e && clip.EndFrame > s;
    }

    private static string TrackLabel(Track track, int index)
        => track.Type == ClipType.Audio ? $"A{index + 1}" : $"V{index + 1}";

    private static bool IsIdentityTransform(Transform t)
        => Math.Abs(t.CenterX - 0.5) < 1e-6 && Math.Abs(t.CenterY - 0.5) < 1e-6
           && Math.Abs(t.Width - 1) < 1e-6 && Math.Abs(t.Height - 1) < 1e-6
           && Math.Abs(t.Rotation) < 1e-6 && !t.FlipHorizontal && !t.FlipVertical;

    private static bool IsIdentityCrop(Crop c)
        => c.Left <= 1e-6 && c.Top <= 1e-6 && c.Right <= 1e-6 && c.Bottom <= 1e-6;

    private static Dictionary<string, object?> TransformDict(Transform t) => new()
    {
        ["centerX"] = Math.Round(t.CenterX, 3),
        ["centerY"] = Math.Round(t.CenterY, 3),
        ["width"] = Math.Round(t.Width, 3),
        ["height"] = Math.Round(t.Height, 3),
        ["rotation"] = Math.Round(t.Rotation, 3),
        ["flipHorizontal"] = t.FlipHorizontal ? true : null,
        ["flipVertical"] = t.FlipVertical ? true : null,
    };

    private static Dictionary<string, object?> TextStyleDict(TextStyle s)
    {
        var d = new Dictionary<string, object?>
        {
            ["fontSize"] = Math.Round(s.FontSize, 1),
            ["alignment"] = s.Alignment.ToString().ToLowerInvariant(),
        };
        if (!string.IsNullOrEmpty(s.FontName)) d["fontName"] = s.FontName;
        if (Math.Abs(s.FontScale - 1) > 1e-6) d["fontScale"] = Math.Round(s.FontScale, 3);
        return d;
    }

    private static Dictionary<string, object?> CropDict(Crop c) => new()
    {
        ["left"] = Math.Round(c.Left, 3),
        ["top"] = Math.Round(c.Top, 3),
        ["right"] = Math.Round(c.Right, 3),
        ["bottom"] = Math.Round(c.Bottom, 3),
    };
}
