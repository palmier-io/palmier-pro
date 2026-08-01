using System.Text.Json;
using PalmierPro.Core.Editing;
using PalmierPro.Core.Models;

namespace PalmierPro.Agent.Tools;

public sealed partial class ToolExecutor
{
    private static ToolResult ApplyLayout(IAgentEditorHost host, JsonElement args)
    {
        var ops = host.EditOperations;
        var timeline = host.ActiveTimeline;
        if (ops is null || timeline is null) return ToolResult.Error("Editor is not ready.");

        var layoutRaw = ToolArgs.String(args, "layout");
        if (layoutRaw is null) return ToolResult.Error("layout is required");
        var layout = VideoLayoutExtensions.FromRawValue(layoutRaw);
        if (layout is null)
            return ToolResult.Error($"unknown layout '{layoutRaw}'");

        var fitRaw = (ToolArgs.String(args, "fit") ?? "fill").ToLowerInvariant();
        var fit = fitRaw == "fit" ? LayoutFit.Fit : LayoutFit.Fill;
        if (ToolArgs.Array(args, "slots") is not { } slotsEl || slotsEl.GetArrayLength() == 0)
            return ToolResult.Error("apply_layout needs a non-empty 'slots' array");

        var slotById = layout.Value.Slots().ToDictionary(s => s.Id, StringComparer.Ordinal);
        var clipIdsBySlot = new Dictionary<string, IReadOnlyList<string>>(StringComparer.Ordinal);
        var mediaBySlot = new Dictionary<string, MediaManifestEntry>(StringComparer.Ordinal);
        var usesMedia = false;
        var usesClip = false;
        var startFrame = ToolArgs.Int(args, "startFrame") ?? 0;
        var endFrame = ToolArgs.Int(args, "endFrame");

        foreach (var entry in slotsEl.EnumerateArray())
        {
            var slotId = ToolArgs.String(entry, "slot");
            if (slotId is null || !slotById.ContainsKey(slotId))
                return ToolResult.Error($"Unknown or missing slot '{slotId}' for layout '{layoutRaw}'.");
            var mediaRef = ToolArgs.String(entry, "mediaRef");
            var clipIds = ToolArgs.StringArray(entry, "clipIds");
            if ((mediaRef is null) == (clipIds.Count == 0))
                return ToolResult.Error($"slot '{slotId}': provide exactly one of mediaRef or clipIds");
            if (mediaRef is not null)
            {
                usesMedia = true;
                var asset = host.ResolveMedia(mediaRef);
                if (asset is null) return ToolResult.Error($"No media '{mediaRef}'.");
                mediaBySlot[slotId] = asset;
            }
            else
            {
                usesClip = true;
                var resolved = ResolveClipIds(host, clipIds);
                if (resolved.Count == 0) return ToolResult.Error($"slot '{slotId}': no matching clips");
                clipIdsBySlot[slotId] = resolved;
            }
        }

        if (usesMedia && usesClip)
            return ToolResult.Error("Don't mix mediaRef and clipIds across slots.");
        if (usesMedia)
        {
            if (endFrame is null || endFrame <= startFrame)
                return ToolResult.Error("Placing new clips requires endFrame > startFrame.");
            var missingMedia = slotById.Keys.Except(mediaBySlot.Keys).ToList();
            if (missingMedia.Count > 0)
                return ToolResult.Error($"Missing slots: {string.Join(", ", missingMedia)}");

            // Insert bottom→top (low z first) so index 0 ends as the topmost after reverse inserts.
            var trackBySlot = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (var slot in layout.Value.Slots().OrderBy(s => s.Z))
            {
                trackBySlot[slot.Id] = ops.InsertTrack(0, ClipType.Video);
            }
            foreach (var slot in layout.Value.Slots())
            {
                var asset = mediaBySlot[slot.Id];
                var ids = ops.PlaceClip(new PlaceClipRequest(
                    asset.Id, asset.Type, asset.Duration,
                    asset.HasAudio ?? false, trackBySlot[slot.Id], startFrame,
                    endFrame.Value - startFrame, AddLinkedAudio: false));
                if (ids.Count == 0) return ToolResult.Error($"Failed to place media in slot '{slot.Id}'.");
                clipIdsBySlot[slot.Id] = [ids[0]];
            }
        }

        var missing = slotById.Keys.Except(clipIdsBySlot.Keys).ToList();
        if (missing.Count > 0)
            return ToolResult.Error($"Missing slots: {string.Join(", ", missing)}");

        double? Aspect(Clip clip)
        {
            var entry = host.ResolveMedia(clip.MediaRef);
            if (entry?.SourceWidth is { } w and > 0 && entry.SourceHeight is { } h and > 0)
                return w / (double)h / (timeline.Width / (double)Math.Max(1, timeline.Height));
            return null;
        }

        if (!ops.ApplyLayoutToClips(layout.Value, fit, clipIdsBySlot, Aspect))
            return ToolResult.Error("apply_layout changed no clips.");

        return ToolResult.OkJson(new
        {
            layout = layout.Value.RawValue(),
            slots = clipIdsBySlot,
            note = usesClip
                ? "Stacking follows track order (index 0 on top); reorder with manage_tracks if needed."
                : (string?)null,
        });
    }

    private static ToolResult SetKeyframes(IAgentEditorHost host, JsonElement args)
    {
        var ops = host.EditOperations;
        if (ops is null) return ToolResult.Error("Editor is not ready.");
        var clipId = ToolArgs.String(args, "clipId");
        var property = ToolArgs.String(args, "property");
        if (clipId is null || property is null)
            return ToolResult.Error("clipId and property are required");
        var resolved = ResolveClipIds(host, [clipId]);
        if (resolved.Count == 0) return ToolResult.Error($"Clip not found: {clipId}");
        clipId = resolved[0];
        if (ToolArgs.Array(args, "keyframes") is not { } rows)
            return ToolResult.Error("Missing required field 'keyframes'");

        bool ok;
        switch (property)
        {
            case "opacity":
                ok = ops.SetKeyframesOpacity(clipId, ParseScalarTrack(rows, 0, 1));
                break;
            case "rotation":
                ok = ops.SetKeyframesRotation(clipId, ParseScalarTrack(rows, null, null));
                break;
            case "volumeDb":
                ok = ops.SetKeyframesVolumeDb(clipId,
                    ParseScalarTrack(rows, VolumeScale.FloorDb, VolumeScale.CeilingDb));
                break;
            case "position":
                ok = ops.SetKeyframesPosition(clipId, ParsePairTrack(rows));
                break;
            case "scale":
                ok = ops.SetKeyframesScale(clipId, ParsePairTrack(rows));
                break;
            case "crop":
                ok = ops.SetKeyframesCrop(clipId, ParseCropTrack(rows));
                break;
            default:
                return ToolResult.Error($"Unknown property '{property}'.");
        }

        if (!ok) return ToolResult.Error("set_keyframes failed.");
        return ToolResult.OkJson(new
        {
            clipId,
            property,
            note = rows.GetArrayLength() == 0 ? $"Cleared {property} keyframes." : null,
        });
    }

    private static ToolResult AddTexts(IAgentEditorHost host, JsonElement args)
    {
        var ops = host.EditOperations;
        var timeline = host.ActiveTimeline;
        if (ops is null || timeline is null) return ToolResult.Error("Editor is not ready.");
        if (ToolArgs.Array(args, "entries") is not { } entries || entries.GetArrayLength() == 0)
            return ToolResult.Error("Missing or empty 'entries' array");

        var specs = new List<TextClipSpec>();
        var omittedTrack = 0;
        var index = 0;
        foreach (var entry in entries.EnumerateArray())
        {
            var content = ToolArgs.String(entry, "content");
            var start = ToolArgs.Int(entry, "startFrame");
            var end = ToolArgs.Int(entry, "endFrame");
            if (content is null || start is null || end is null)
                return ToolResult.Error($"entries[{index}]: content, startFrame, endFrame required");
            if (end <= start) return ToolResult.Error($"entries[{index}]: endFrame must exceed startFrame");
            var trackIndex = ToolArgs.Int(entry, "trackIndex");
            if (trackIndex is null) omittedTrack++;
            else if (trackIndex < 0 || trackIndex >= timeline.Tracks.Count
                     || !ClipType.Text.IsCompatible(timeline.Tracks[trackIndex.Value].Type))
                return ToolResult.Error($"entries[{index}]: invalid trackIndex");

            var style = new TextStyle();
            if (ToolArgs.Number(entry, "fontSize") is { } size) style.FontSize = size;
            if (ToolArgs.String(entry, "fontName") is { } font) style.FontName = font;

            var transform = Transform.FromCenter(0.5, 0.5, 0.8, 0.25);
            if (entry.TryGetProperty("transform", out var t) && t.ValueKind == JsonValueKind.Object)
            {
                var cx = ToolArgs.Number(t, "centerX") ?? 0.5;
                var cy = ToolArgs.Number(t, "centerY") ?? 0.5;
                var w = ToolArgs.Number(t, "width") ?? 0.8;
                var h = ToolArgs.Number(t, "height") ?? 0.25;
                transform = Transform.FromCenter(cx, cy, w, h);
            }

            specs.Add(new TextClipSpec(
                trackIndex ?? -1, start.Value, end.Value - start.Value,
                content, style, transform));
            index++;
        }

        if (omittedTrack != 0 && omittedTrack != specs.Count)
            return ToolResult.Error("Mixed trackIndex: set on every entry or omit on every entry.");

        if (omittedTrack == specs.Count)
        {
            var newIdx = ops.InsertTrack(0, ClipType.Video);
            specs = specs.Select(s => s with { TrackIndex = newIdx }).ToList();
        }

        var ids = ops.PlaceTextClips(specs);
        if (ids.Count == 0) return ToolResult.Error("Failed to place text clips.");
        return ToolResult.OkJson(new { createdClipIds = ids });
    }

    private static KeyframeTrack<double>? ParseScalarTrack(
        JsonElement rows, double? min, double? max)
    {
        var track = new KeyframeTrack<double>();
        foreach (var row in rows.EnumerateArray())
        {
            int? frame;
            double? value;
            string? interp = null;
            // Mac row: [frame, value, interp?]
            if (row.ValueKind == JsonValueKind.Array && row.GetArrayLength() >= 2)
            {
                frame = row[0].TryGetInt32(out var f) ? f : (int)Math.Round(row[0].GetDouble());
                value = row[1].GetDouble();
                if (row.GetArrayLength() >= 3 && row[2].ValueKind == JsonValueKind.String)
                    interp = row[2].GetString();
            }
            else
            {
                frame = ToolArgs.Int(row, "frame");
                value = ToolArgs.Number(row, "value") ?? ToolArgs.Number(row, "decibels");
                interp = ToolArgs.String(row, "interpolation");
            }
            if (frame is null || value is null) continue;
            var v = value.Value;
            if (min is not null) v = Math.Max(min.Value, v);
            if (max is not null) v = Math.Min(max.Value, v);
            track.Upsert(new Keyframe<double>
            {
                Frame = frame.Value,
                Value = v,
                InterpolationOut = ParseInterp(interp),
            });
        }
        return track.IsActive ? track : null;
    }

    private static KeyframeTrack<AnimPair>? ParsePairTrack(JsonElement rows)
    {
        var track = new KeyframeTrack<AnimPair>();
        foreach (var row in rows.EnumerateArray())
        {
            int? frame;
            double a, b;
            string? interp = null;
            // Mac row: [frame, x, y, interp?]
            if (row.ValueKind == JsonValueKind.Array && row.GetArrayLength() >= 3)
            {
                frame = row[0].TryGetInt32(out var f) ? f : (int)Math.Round(row[0].GetDouble());
                a = row[1].GetDouble();
                b = row[2].GetDouble();
                if (row.GetArrayLength() >= 4 && row[3].ValueKind == JsonValueKind.String)
                    interp = row[3].GetString();
            }
            else
            {
                frame = ToolArgs.Int(row, "frame");
                if (frame is null) continue;
                if (row.TryGetProperty("value", out var val) && val.ValueKind == JsonValueKind.Array
                    && val.GetArrayLength() >= 2)
                {
                    a = val[0].GetDouble();
                    b = val[1].GetDouble();
                }
                else if (ToolArgs.Number(row, "x") is { } x && ToolArgs.Number(row, "y") is { } y)
                {
                    a = x; b = y;
                }
                else continue;
                interp = ToolArgs.String(row, "interpolation");
            }
            if (frame is null) continue;
            track.Upsert(new Keyframe<AnimPair>
            {
                Frame = frame.Value,
                Value = new AnimPair(a, b),
                InterpolationOut = ParseInterp(interp),
            });
        }
        return track.IsActive ? track : null;
    }

    private static KeyframeTrack<Crop>? ParseCropTrack(JsonElement rows)
    {
        var track = new KeyframeTrack<Crop>();
        foreach (var row in rows.EnumerateArray())
        {
            int? frame;
            Crop crop;
            string? interp = null;
            // Mac row: [frame, left, top, right, bottom, interp?]
            if (row.ValueKind == JsonValueKind.Array && row.GetArrayLength() >= 5)
            {
                frame = row[0].TryGetInt32(out var f) ? f : (int)Math.Round(row[0].GetDouble());
                crop = new Crop
                {
                    Left = row[1].GetDouble(),
                    Top = row[2].GetDouble(),
                    Right = row[3].GetDouble(),
                    Bottom = row[4].GetDouble(),
                };
                if (row.GetArrayLength() >= 6 && row[5].ValueKind == JsonValueKind.String)
                    interp = row[5].GetString();
            }
            else
            {
                frame = ToolArgs.Int(row, "frame");
                if (frame is null || !row.TryGetProperty("value", out var val)
                    || val.ValueKind != JsonValueKind.Object) continue;
                crop = new Crop
                {
                    Left = ToolArgs.Number(val, "left") ?? 0,
                    Top = ToolArgs.Number(val, "top") ?? 0,
                    Right = ToolArgs.Number(val, "right") ?? 0,
                    Bottom = ToolArgs.Number(val, "bottom") ?? 0,
                };
                interp = ToolArgs.String(row, "interpolation");
            }
            track.Upsert(new Keyframe<Crop>
            {
                Frame = frame.Value,
                Value = crop,
                InterpolationOut = ParseInterp(interp),
            });
        }
        return track.IsActive ? track : null;
    }

    private static Interpolation ParseInterp(string? raw) => (raw ?? "smooth").ToLowerInvariant() switch
    {
        "linear" => Interpolation.Linear,
        "hold" => Interpolation.Hold,
        _ => Interpolation.Smooth,
    };
}
