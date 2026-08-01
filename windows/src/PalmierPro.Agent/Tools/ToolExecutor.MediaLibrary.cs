using System.Text.Json;
using PalmierPro.Core.Models;
using PalmierPro.Core.Project;
using PalmierPro.Core.Serialization;

namespace PalmierPro.Agent.Tools;

public sealed partial class ToolExecutor
{
    private static ToolResult ImportMedia(IAgentEditorHost host, JsonElement args)
    {
        // Mac shape: source:{path|url|bytes|matte}.
        string? path = null;
        string? folder = ToolArgs.String(args, "folder");
        var stagedTemps = new List<string>();
        try
        {
            if (args.TryGetProperty("source", out var source) && source.ValueKind == JsonValueKind.Object)
            {
                path = ToolArgs.String(source, "path");
                if (path is null && ToolArgs.String(source, "url") is { } url)
                {
                    path = StageUrlToTemp(url, stagedTemps);
                    if (path is null)
                        return ToolResult.Error($"import_media could not download url: {url}");
                }
                if (path is null && source.TryGetProperty("bytes", out var bytesEl))
                {
                    path = StageBytesToTemp(bytesEl, ToolArgs.String(source, "name") ?? ToolArgs.String(source, "filename"), stagedTemps);
                    if (path is null)
                        return ToolResult.Error("import_media source.bytes must be base64 (or {data,name}).");
                }
                if (path is null && source.TryGetProperty("matte", out _))
                    return ToolResult.Error("import_media matte is not yet implemented on Windows.");
            }
            path ??= ToolArgs.String(args, "path");
            var paths = ToolArgs.StringArray(args, "paths").ToList();
            if (path is not null) paths.Insert(0, path);
            if (paths.Count == 0)
                return ToolResult.Error("import_media requires source.path, source.url, source.bytes, or paths[].");

            var receipts = host.ImportMediaFromPaths(paths, folder);
            if (receipts.Count == 0)
                return ToolResult.Error("No media imported.");
            if (receipts.Count == 1)
            {
                var r = receipts[0];
                return ToolResult.OkJson(new
                {
                    mediaRef = r.MediaRef,
                    name = r.Name,
                    type = r.Type,
                    status = r.Status,
                    note = r.Note,
                });
            }
            return ToolResult.OkJson(new
            {
                status = "ready",
                imported = receipts.Count,
                media = receipts.Select(r => new { mediaRef = r.MediaRef, name = r.Name, type = r.Type }).ToList(),
            });
        }
        finally
        {
            foreach (var tmp in stagedTemps)
            {
                try { if (File.Exists(tmp)) File.Delete(tmp); } catch { /* best-effort */ }
            }
        }
    }

    private static string? StageUrlToTemp(string url, List<string> staged)
    {
        try
        {
            if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)
                || (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
                return null;
            var ext = Path.GetExtension(uri.AbsolutePath);
            if (string.IsNullOrWhiteSpace(ext) || ext.Length > 8) ext = ".bin";
            var dest = Path.Combine(Path.GetTempPath(), $"palmier-import-{Uuid.NewString()}{ext}");
            using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
            using var response = http.GetAsync(uri).GetAwaiter().GetResult();
            response.EnsureSuccessStatusCode();
            using var stream = response.Content.ReadAsStream();
            using var file = File.Create(dest);
            stream.CopyTo(file);
            staged.Add(dest);
            return dest;
        }
        catch
        {
            return null;
        }
    }

    private static string? StageBytesToTemp(JsonElement bytesEl, string? nameHint, List<string> staged)
    {
        try
        {
            string? b64 = null;
            string? name = nameHint;
            if (bytesEl.ValueKind == JsonValueKind.String)
                b64 = bytesEl.GetString();
            else if (bytesEl.ValueKind == JsonValueKind.Object)
            {
                b64 = ToolArgs.String(bytesEl, "data") ?? ToolArgs.String(bytesEl, "base64");
                name ??= ToolArgs.String(bytesEl, "name") ?? ToolArgs.String(bytesEl, "filename");
            }
            if (string.IsNullOrWhiteSpace(b64)) return null;
            var bytes = Convert.FromBase64String(b64.Trim());
            var ext = Path.GetExtension(name ?? "");
            if (string.IsNullOrWhiteSpace(ext)) ext = ".bin";
            var dest = Path.Combine(Path.GetTempPath(),
                $"palmier-import-{Uuid.NewString()}{ext}");
            File.WriteAllBytes(dest, bytes);
            staged.Add(dest);
            return dest;
        }
        catch
        {
            return null;
        }
    }

    private static ToolResult OrganizeMedia(IAgentEditorHost host, JsonElement args)
    {
        var action = (ToolArgs.String(args, "action") ?? "").ToLowerInvariant();
        if (action is "nest" or "unnest")
            return NestOrUnnest(host, args, action);

        var manifest = host.Manifest;
        var created = new List<string>();
        var moved = 0;
        var renamed = 0;
        var deletedAssets = 0;
        var deletedFolders = 0;

        if (ToolArgs.Array(args, "createFolders") is { } creates)
        {
            foreach (var entry in creates.EnumerateArray())
            {
                var name = ToolArgs.String(entry, "name") ?? entry.GetString();
                var parent = ToolArgs.String(entry, "parent") ?? ToolArgs.String(entry, "into");
                if (string.IsNullOrWhiteSpace(name)) continue;
                // Allow string path form "A/B"
                if (name.Contains('/'))
                {
                    MediaFolderOps.ResolveOrCreateFolder(manifest, name);
                    created.Add(name);
                }
                else
                {
                    MediaFolderOps.CreateFolder(manifest, name, parent);
                    created.Add(parent is null ? name : $"{parent}/{name}");
                }
            }
        }

        if (ToolArgs.Array(args, "moves") is { } moves)
        {
            foreach (var move in moves.EnumerateArray())
            {
                var into = ToolArgs.String(move, "into");
                string? folderId = null;
                if (!string.IsNullOrWhiteSpace(into))
                    folderId = MediaFolderOps.ResolveOrCreateFolder(manifest, into);
                var items = ToolArgs.StringArray(move, "items");
                foreach (var item in items)
                {
                    var entry = host.ResolveMedia(item);
                    if (entry is not null)
                    {
                        entry.FolderId = folderId;
                        moved++;
                        continue;
                    }
                    // Folder path move
                    var fromId = MediaFolderOps.ResolveFolderId(manifest, item);
                    if (fromId is null) continue;
                    var folder = manifest.Folders.FirstOrDefault(f => f.Id == fromId);
                    if (folder is null) continue;
                    folder.ParentFolderId = folderId;
                    moved++;
                }
            }
        }

        if (ToolArgs.Array(args, "renames") is { } renames)
        {
            foreach (var row in renames.EnumerateArray())
            {
                var item = ToolArgs.String(row, "item");
                var name = ToolArgs.String(row, "name");
                if (item is null || string.IsNullOrWhiteSpace(name)) continue;
                var entry = host.ResolveMedia(item);
                if (entry is not null)
                {
                    entry.Name = name.Trim();
                    renamed++;
                    continue;
                }
                var folderId = MediaFolderOps.ResolveFolderId(manifest, item);
                var folder = manifest.Folders.FirstOrDefault(f => f.Id == folderId);
                if (folder is not null)
                {
                    folder.Name = name.Trim();
                    renamed++;
                }
            }
        }

        if (ToolArgs.Array(args, "deletes") is { } deletes)
        {
            var assetDeletes = new List<string>();
            foreach (var raw in deletes.EnumerateArray())
            {
                var item = raw.ValueKind == JsonValueKind.String ? raw.GetString() : ToolArgs.String(raw, "item");
                if (item is null) continue;
                var entry = host.ResolveMedia(item);
                if (entry is not null)
                {
                    assetDeletes.Add(entry.Id);
                    continue;
                }
                var folderId = MediaFolderOps.ResolveFolderId(manifest, item);
                if (folderId is null) continue;
                manifest.Folders.RemoveAll(f => f.Id == folderId);
                foreach (var e in manifest.Entries.Where(e => e.FolderId == folderId))
                    e.FolderId = null;
                deletedFolders++;
            }
            if (assetDeletes.Count > 0)
                deletedAssets = host.DeleteMediaAssets(assetDeletes);
        }

        if (created.Count == 0 && moved == 0 && renamed == 0 && deletedAssets == 0 && deletedFolders == 0)
            return ToolResult.Error(
                "organize_media: nothing to do. Pass createFolders, moves, renames, deletes, or action nest|unnest.");

        host.NotifyManifestChanged();
        return ToolResult.OkJson(new
        {
            createdFolders = created.Count == 0 ? null : created,
            moved = moved == 0 ? null : (int?)moved,
            renamed = renamed == 0 ? null : (int?)renamed,
            deleted = (deletedAssets == 0 && deletedFolders == 0) ? null : new
            {
                assets = deletedAssets,
                folders = deletedFolders,
            },
        });
    }

    private static ToolResult NestOrUnnest(IAgentEditorHost host, JsonElement args, string action)
    {
        var ops = host.EditOperations;
        var timeline = host.ActiveTimeline;
        if (ops is null || timeline is null) return ToolResult.Error("Editor is not ready.");

        var clipIds = ResolveClipIds(host, ToolArgs.StringArray(args, "clipIds"));
        if (clipIds.Count == 0)
            clipIds = ResolveClipIds(host, ToolArgs.StringArray(args, "ids"));
        if (clipIds.Count == 0)
            return ToolResult.Error($"organize_media action={action} requires clipIds (or ids).");

        var snapshot = MutationDelta.Snapshot(timeline);
        if (action == "nest")
        {
            var nested = ops.NestClips(clipIds, ToolArgs.String(args, "name"), host.RegisterTimeline);
            if (nested is null)
                return ToolResult.Error("Nest refused (no valid clips).");
            host.NotifyTimelineChanged();
            return MutationDelta.Result(host, snapshot, [nested.Value.CarrierClipId],
                new Dictionary<string, object?>
                {
                    ["action"] = "nest",
                    ["nestedTimelineId"] = nested.Value.Nested.Id,
                    ["carrierClipId"] = nested.Value.CarrierClipId,
                });
        }

        var unnested = 0;
        var carriers = new List<string>();
        var all = host.Timelines.ToDictionary(t => t.Id, t => t);
        foreach (var id in clipIds)
        {
            if (ops.UnnestClip(id, all))
            {
                unnested++;
                carriers.Add(id);
            }
        }
        if (unnested == 0)
            return ToolResult.Error("Unnest refused (no sequence carriers).");
        host.NotifyTimelineChanged();
        return MutationDelta.Result(host, snapshot, null,
            new Dictionary<string, object?>
            {
                ["action"] = "unnest",
                ["unnested"] = unnested,
                ["carrierClipIds"] = carriers,
            });
    }

    private static ToolResult CaptureFrame(IAgentEditorHost host, JsonElement args)
    {
        var timelineFrame = ToolArgs.Int(args, "timelineFrame") ?? ToolArgs.Int(args, "atFrame");
        var mediaRef = ToolArgs.String(args, "mediaRef");
        var sourceSeconds = ToolArgs.Number(args, "sourceSeconds") ?? ToolArgs.Number(args, "atSeconds");
        var name = ToolArgs.String(args, "name");

        if (timelineFrame is not null && mediaRef is not null)
            return ToolResult.Error("capture_frame: pass timelineFrame XOR mediaRef+sourceSeconds.");
        if (timelineFrame is null && (mediaRef is null || sourceSeconds is null))
            return ToolResult.Error("capture_frame requires timelineFrame or mediaRef+sourceSeconds.");

        var receipt = host.CaptureFrameToMedia(timelineFrame, mediaRef, sourceSeconds, name);
        if (receipt is null)
            return ToolResult.Error("Could not capture frame.");
        return ToolResult.OkJson(new
        {
            status = "ready",
            mediaRef = receipt.MediaRef,
            name = receipt.Name,
            type = "image",
            mimeType = "image/png",
            width = receipt.Width,
            height = receipt.Height,
            capturedFrom = receipt.CapturedFrom,
        });
    }

    private static ToolResult InspectColor(IAgentEditorHost host, JsonElement args)
    {
        var clipId = ToolArgs.String(args, "clipId");
        var mediaRef = ToolArgs.String(args, "mediaRef");
        if ((clipId is null) == (mediaRef is null))
            return ToolResult.Error("inspect_color requires exactly one of clipId or mediaRef.");
        var atFrame = ToolArgs.Int(args, "atFrame");
        var receipt = host.InspectColor(clipId, mediaRef, atFrame);
        if (receipt is null)
            return ToolResult.Error("Could not sample color.");
        return ToolResult.OkJson(new
        {
            readout = receipt.Readout,
            note = receipt.Note,
        });
    }

    private static ToolResult SyncClips(IAgentEditorHost host, JsonElement args)
    {
        var mode = (ToolArgs.String(args, "mode")
            ?? ToolArgs.String(args, "method")
            ?? "auto").ToLowerInvariant();
        var reference = ToolArgs.String(args, "referenceClipId");
        var targets = ToolArgs.StringArray(args, "targetClipIds").ToList();
        if (ToolArgs.String(args, "targetClipId") is { } one) targets.Add(one);

        // Alternate shape: clipIds[0] = reference, rest = targets.
        var clipIds = ResolveClipIds(host, ToolArgs.StringArray(args, "clipIds"));
        if (reference is null && clipIds.Count >= 2)
        {
            reference = clipIds[0];
            targets.AddRange(clipIds.Skip(1));
        }
        if (reference is null) return ToolResult.Error("referenceClipId is required (or clipIds with 2+ entries)");
        if (targets.Count == 0) return ToolResult.Error("targetClipId or targetClipIds is required");

        if (mode is not ("auto" or "audio" or "timecode"))
            return ToolResult.Error("mode must be auto, audio, or timecode");

        // Mac auto: timecode first, then audio cross-correlation.
        if (mode is "auto" or "timecode")
        {
            var tcSynced = host.SyncClipsTimecode(reference, targets);
            if (tcSynced.Count > 0)
            {
                return ToolResult.OkJson(new
                {
                    referenceClipId = reference,
                    mode = "timecode",
                    synced = tcSynced.Select(s => new
                    {
                        clipId = s.ClipId,
                        offsetFrames = s.OffsetFrames,
                        confidence = Math.Round(s.Confidence, 3),
                        method = s.Method,
                    }).ToList(),
                });
            }
            if (mode is "timecode")
            {
                return ToolResult.OkJson(new
                {
                    referenceClipId = reference,
                    mode = "timecode",
                    synced = Array.Empty<object>(),
                    note = "No embedded BWF/Sony-rtmd timecode found on reference or targets. " +
                           "QuickTime tmcd is not available via Media Foundation — use mode=audio.",
                });
            }
        }

        var window = ToolArgs.Number(args, "searchWindowSeconds") ?? 30;
        var minConf = ToolArgs.Number(args, "minConfidence") ?? 0.5;
        var synced = host.SyncClipsAudio(reference, targets, window, minConf);
        if (synced.Count == 0)
            return ToolResult.Error("No clips synced (low confidence or missing audio).");
        return ToolResult.OkJson(new
        {
            referenceClipId = reference,
            mode = "audio",
            synced = synced.Select(s => new
            {
                clipId = s.ClipId,
                offsetFrames = s.OffsetFrames,
                confidence = Math.Round(s.Confidence, 3),
                method = s.Method,
            }).ToList(),
        });
    }

    private static ToolResult UpdateText(IAgentEditorHost host, JsonElement args)
    {
        var ops = host.EditOperations;
        var timeline = host.ActiveTimeline;
        if (ops is null || timeline is null) return ToolResult.Error("Editor is not ready.");

        var clipIds = ResolveClipIds(host, ToolArgs.StringArray(args, "clipIds"));
        var captionGroupId = ToolArgs.String(args, "captionGroupId");
        if (clipIds.Count == 0 && captionGroupId is not null)
        {
            clipIds = timeline.Tracks.SelectMany(t => t.Clips)
                .Where(c => c.CaptionGroupId == captionGroupId
                    || (c.CaptionGroupId?.StartsWith(captionGroupId, StringComparison.OrdinalIgnoreCase) ?? false))
                .Select(c => c.Id)
                .ToList();
        }
        if (clipIds.Count == 0)
            return ToolResult.Error("clipIds or captionGroupId is required");

        string? content = ToolArgs.String(args, "content");
        TextStyle? style = null;
        if (args.TryGetProperty("style", out var styleEl) && styleEl.ValueKind == JsonValueKind.Object)
        {
            style = new TextStyle();
            if (ToolArgs.Number(styleEl, "fontSize") is { } fs) style.FontSize = fs;
            if (ToolArgs.String(styleEl, "fontName") is { } fn) style.FontName = fn;
        }
        Transform? transform = null;
        if (args.TryGetProperty("transform", out var t) && t.ValueKind == JsonValueKind.Object)
        {
            transform = Transform.FromCenter(
                ToolArgs.Number(t, "centerX") ?? 0.5,
                ToolArgs.Number(t, "centerY") ?? 0.5,
                ToolArgs.Number(t, "width") ?? 0.8,
                ToolArgs.Number(t, "height") ?? 0.25);
        }

        var snapshot = MutationDelta.Snapshot(timeline);
        if (!ops.UpdateTextClips(clipIds, content, style, transform, null, null))
            return ToolResult.Error("update_text changed no text clips.");
        host.NotifyTimelineChanged();
        return MutationDelta.Result(host, snapshot, clipIds, new Dictionary<string, object?>
        {
            ["captionGroupId"] = captionGroupId,
            ["clipIds"] = clipIds,
        });
    }
}
