using System.Text.Json;
using PalmierPro.Core.Export;
using PalmierPro.Core.Models;
using PalmierPro.Core.Transcription;

namespace PalmierPro.Agent.Tools;

public sealed partial class ToolExecutor
{
    private static ToolResult GetMedia(IAgentEditorHost host, JsonElement args)
    {
        var ids = ToolArgs.StringArray(args, "ids").ToHashSet(StringComparer.OrdinalIgnoreCase);
        var folder = ToolArgs.String(args, "folder");
        var pending = ToolArgs.Bool(args, "pending");

        var assets = host.Manifest.Entries
            .Where(e => ids.Count == 0 || ids.Contains(e.Id) || ids.Any(id => e.Id.StartsWith(id, StringComparison.OrdinalIgnoreCase)))
            .Where(e => folder is null || string.Equals(e.FolderId, folder, StringComparison.OrdinalIgnoreCase))
            .Where(e => pending is null || (pending.Value
                ? e.GenerationStatus is not null && e.GenerationStatus != "ready"
                : e.GenerationStatus is null or "ready"))
            .Select(e => new Dictionary<string, object?>
            {
                ["id"] = e.Id,
                ["name"] = e.Name,
                ["type"] = e.Type.ToString().ToLowerInvariant(),
                ["durationSeconds"] = e.Duration,
                ["width"] = e.SourceWidth,
                ["height"] = e.SourceHeight,
                ["fps"] = e.SourceFPS,
                ["hasAudio"] = e.HasAudio,
                ["folderId"] = e.FolderId,
                ["generationStatus"] = e.GenerationStatus,
            })
            .ToList();

        var timelines = host.Timelines.Select(t => new Dictionary<string, object?>
        {
            ["timelineId"] = t.Id,
            ["name"] = t.Name,
            ["active"] = t.Id == host.ActiveTimelineId ? true : null,
            ["durationSeconds"] = t.TotalFrames / (double)Math.Max(1, t.Fps),
        }).ToList();

        return ToolResult.OkJson(new
        {
            assets,
            timelines,
            projectName = host.ProjectName,
        });
    }

    private static ToolResult InspectMedia(IAgentEditorHost host, JsonElement args)
    {
        var mediaRef = ToolArgs.String(args, "mediaRef");
        if (mediaRef is null) return ToolResult.Error("mediaRef is required");
        var entry = host.Manifest.Entries.FirstOrDefault(e =>
            e.Id == mediaRef || e.Id.StartsWith(mediaRef, StringComparison.OrdinalIgnoreCase));
        if (entry is null) return ToolResult.Error($"No media with id '{mediaRef}'.");

        var overview = ToolArgs.Bool(args, "overview") ?? false;
        var wordTimestamps = ToolArgs.Bool(args, "wordTimestamps") ?? false;
        var language = ToolArgs.String(args, "language");
        var clipId = ToolArgs.String(args, "clipId");
        var maxFrames = Math.Clamp(ToolArgs.Int(args, "maxFrames") ?? 6, 1, 12);
        var startSeconds = ToolArgs.Number(args, "startSeconds") ?? 0;
        var endSeconds = ToolArgs.Number(args, "endSeconds") ?? Math.Max(entry.Duration, 0.01);

        var times = new List<double>();
        if (!overview && entry.Type is ClipType.Video or ClipType.Image)
        {
            if (entry.Type == ClipType.Image)
                times.Add(0);
            else
            {
                var span = Math.Max(0.01, endSeconds - startSeconds);
                for (var i = 0; i < maxFrames; i++)
                    times.Add(startSeconds + span * (i + 0.5) / maxFrames);
            }
        }

        var images = entry.Type is ClipType.Audio
            ? Array.Empty<InspectFrameImage>()
            : host.RenderMediaInspectFrames(entry.Id, times, overview: overview);

        object? transcription = null;
        string? transcriptionError = null;
        object? timelineMapping = null;
        if (entry.Type is ClipType.Video or ClipType.Audio)
        {
            var path = ResolveMediaPath(host, entry.Id);
            if (path is null)
                transcriptionError = "Media file not on disk.";
            else
            {
                try
                {
                    var fps = Math.Max(1, host.ActiveTimeline?.Fps ?? 30);
                    Clip? mappedClip = null;
                    if (clipId is not null && host.EditOperations?.FindClip(clipId) is { } found)
                    {
                        if (found.Clip.MediaRef != entry.Id
                            && !found.Clip.MediaRef.StartsWith(entry.Id, StringComparison.OrdinalIgnoreCase))
                            return ToolResult.Error($"Clip {clipId} does not reference mediaRef {entry.Id}.");
                        mappedClip = found.Clip;
                    }

                    var doc = LocalStt.TranscribeFile(path, entry.Id, fps, language);
                    TranscriptCache.Shared.Store(host.PackagePath, doc);
                    transcription = BuildTranscriptionMeta(doc, fps, mappedClip, wordTimestamps,
                        startSeconds, endSeconds);
                    if (mappedClip is not null)
                    {
                        timelineMapping = new
                        {
                            clipId = mappedClip.Id,
                            clipStartFrame = mappedClip.StartFrame,
                            clipEndFrame = mappedClip.EndFrame,
                            fps,
                            note = "transcription segments/words are project frames for this clip.",
                        };
                    }
                }
                catch (Exception ex)
                {
                    transcriptionError = ex.Message;
                }
            }
        }

        var meta = new Dictionary<string, object?>
        {
            ["id"] = entry.Id,
            ["name"] = entry.Name,
            ["type"] = entry.Type.ToString().ToLowerInvariant(),
            ["durationSeconds"] = entry.Duration,
            ["width"] = entry.SourceWidth ?? images.FirstOrDefault()?.Width,
            ["height"] = entry.SourceHeight ?? images.FirstOrDefault()?.Height,
            ["fps"] = entry.SourceFPS,
            ["hasAudio"] = entry.HasAudio,
            ["overview"] = overview,
            ["frameTimestamps"] = images.Select(i => i.Label).ToList(),
            ["imageCount"] = images.Count,
            ["transcription"] = transcription,
            ["transcriptionError"] = transcriptionError,
            ["timelineMapping"] = timelineMapping,
            ["timeRange"] = new[] { startSeconds, endSeconds },
        };

        if (images.Count == 0)
            return ToolResult.OkJson(meta);

        return ToolResult.OkImages(
            images.Select(i => new ToolImageBlock(Convert.ToBase64String(i.Bytes), i.MediaType)),
            meta);
    }

    private static object BuildTranscriptionMeta(
        TranscriptDocument doc, int fps, Clip? mappedClip, bool includeWords,
        double windowStart, double windowEnd)
    {
        const int maxSegments = 400;
        const int maxWords = 2000;
        var useFrames = mappedClip is not null;

        bool InWindow(double startSec, double endSec)
            => endSec >= windowStart && startSec <= windowEnd;

        object SegRow(TranscriptSegment s)
        {
            var startSec = s.StartSeconds ?? s.StartFrame / (double)fps;
            var endSec = s.EndSeconds ?? s.EndFrame / (double)fps;
            if (useFrames && mappedClip is not null)
            {
                var start = MapSourceToTimeline(startSec, mappedClip, fps);
                var end = MapSourceToTimeline(endSec, mappedClip, fps);
                return new object[] { s.Text, start, Math.Max(start, end) };
            }
            return new object[] { s.Text, Math.Round(startSec, 2), Math.Round(endSec, 2) };
        }

        var segs = doc.Segments
            .Where(s =>
            {
                var a = s.StartSeconds ?? s.StartFrame / (double)fps;
                var b = s.EndSeconds ?? s.EndFrame / (double)fps;
                return InWindow(a, b);
            })
            .Select(SegRow)
            .ToList();

        var result = new Dictionary<string, object?>
        {
            ["timing"] = useFrames ? "projectFrames" : "sourceSeconds",
            ["language"] = doc.Language,
            ["source"] = doc.Source,
            ["text"] = doc.Text,
            ["segments"] = segs.Take(maxSegments).ToList(),
        };
        if (segs.Count > maxSegments)
        {
            result["totalSegments"] = segs.Count;
            result["segmentsNote"] = $"First {maxSegments} of {segs.Count} segments.";
        }

        if (includeWords)
        {
            var words = doc.Words
                .Where(w =>
                {
                    var a = w.StartSeconds ?? w.StartFrame / (double)fps;
                    var b = w.EndSeconds ?? w.EndFrame / (double)fps;
                    return InWindow(a, b);
                })
                .Select(w =>
                {
                    var startSec = w.StartSeconds ?? w.StartFrame / (double)fps;
                    var endSec = w.EndSeconds ?? w.EndFrame / (double)fps;
                    if (useFrames && mappedClip is not null)
                    {
                        var start = MapSourceToTimeline(startSec, mappedClip, fps);
                        var end = MapSourceToTimeline(endSec, mappedClip, fps);
                        return new object[] { w.Text, start, Math.Max(start, end) };
                    }
                    return new object[] { w.Text, Math.Round(startSec, 2), Math.Round(endSec, 2) };
                })
                .ToList();
            result["words"] = words.Take(maxWords).ToList();
            if (words.Count > maxWords)
            {
                result["totalWords"] = words.Count;
                result["wordsNote"] = $"First {maxWords} of {words.Count} words.";
            }
        }
        return result;
    }

    private static int MapSourceToTimeline(double sourceSeconds, Clip clip, int fps)
    {
        var sourceFrame = sourceSeconds * fps;
        var visibleStart = clip.TrimStartFrame;
        var timeline = clip.StartFrame + (sourceFrame - visibleStart) / Math.Max(0.0001, clip.Speed);
        return (int)Math.Round(timeline);
    }

    private static ToolResult ExportProject(IAgentEditorHost host, JsonElement args)
    {
        var mode = (ToolArgs.String(args, "mode") ?? "video").ToLowerInvariant();
        var codec = (ToolArgs.String(args, "codec") ?? "h264").ToLowerInvariant();
        var quality = ToolArgs.String(args, "quality");
        var resolution = ParseResolution(ToolArgs.String(args, "resolution"));
        var overwrite = ToolArgs.Bool(args, "overwrite") ?? false;

        var format = mode switch
        {
            "xml" => ExportFormat.Xml,
            "fcpxml" => ExportFormat.Fcpxml,
            "palmier" => ExportFormat.Palmier,
            _ => codec switch
            {
                "h265" or "hevc" => ExportFormat.H265,
                "hevchdr" or "hevc_hdr" or "hdr" => ExportFormat.HevcHdr,
                "dnxhr" or "utvideo" or "prores" => ExportFormat.ProRes,
                _ => ExportFormat.H264,
            },
        };

        if (codec is "dnxhr" or "utvideo")
            return ToolResult.Error(ExportPlatformSupport.MezzanineGuidance);
        if (ExportPlatformSupport.RefusalMessage(format) is { } refusal)
            return ToolResult.Error(refusal);

        var downloads = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        Directory.CreateDirectory(downloads);
        var outputPath = ToolArgs.String(args, "outputPath")
            ?? Path.Combine(downloads, $"{Sanitize(host.ProjectName)}.{format.FileExtension()}");

        if ((File.Exists(outputPath) || Directory.Exists(outputPath)) && !overwrite)
            return ToolResult.Error($"Output already exists: {outputPath}. Pass overwrite=true to replace.");

        try
        {
            var job = host.ExportQueue.Enqueue(new ExportRequest
            {
                ProjectId = host.ActiveTimelineId ?? host.ProjectName,
                Filename = Path.GetFileName(outputPath),
                OutputPath = outputPath,
                Format = format,
                Resolution = resolution,
                Source = ExportJobSource.Agent,
                TimelineId = ToolArgs.String(args, "timelineId") ?? host.ActiveTimelineId,
                Overwrite = overwrite || !(File.Exists(outputPath) || Directory.Exists(outputPath)),
                Quality = quality,
            });
            var note = format == ExportFormat.Palmier
                ? "Package export queued. Use manage_exports to poll."
                : quality is not null && (quality.Contains("mezz", StringComparison.OrdinalIgnoreCase)
                                          || quality.Equals("high", StringComparison.OrdinalIgnoreCase))
                    ? ExportPlatformSupport.MezzanineGuidance + " Export queued — use manage_exports to poll."
                    : "Export queued in the background. Use manage_exports to poll.";
            return ToolResult.OkJson(new
            {
                jobId = job.Id,
                status = job.Status.ToString().ToLowerInvariant(),
                outputPath = job.OutputPath,
                format = format.ToString().ToLowerInvariant(),
                quality,
                note,
            });
        }
        catch (Exception ex)
        {
            return ToolResult.Error(ex.Message);
        }
    }

    private static ToolResult ManageExports(IAgentEditorHost host, JsonElement args)
    {
        var action = (ToolArgs.String(args, "action") ?? "list").ToLowerInvariant();
        var jobId = ToolArgs.String(args, "jobId");
        var jobs = host.ExportQueue.Jobs;

        switch (action)
        {
            case "list":
                return ToolResult.OkJson(new
                {
                    jobs = jobs.Select(JobDto).ToList(),
                });
            case "get":
                if (jobId is null) return ToolResult.Error("jobId is required");
                var job = FindJob(jobs, jobId);
                if (job is null) return ToolResult.Error($"No export job '{jobId}'.");
                return ToolResult.OkJson(JobDto(job));
            case "cancel":
                if (jobId is null) return ToolResult.Error("jobId is required");
                var target = FindJob(jobs, jobId);
                if (target is null) return ToolResult.Error($"No export job '{jobId}'.");
                host.ExportQueue.Cancel(target.Id);
                return ToolResult.OkJson(new { jobId = target.Id, status = "canceling" });
            default:
                return ToolResult.Error("action must be list, get, or cancel");
        }
    }

    private static ToolResult ListModels(IAgentEditorHost host)
    {
        try
        {
            PalmierPro.Cloud.Generation.ModelCatalog.Shared.RefreshAsync()
                .GetAwaiter().GetResult();
        }
        catch
        {
            // Offline / unconfigured — still return credit gate status.
        }
        return ToolResult.OkJson(PalmierPro.Cloud.Generation.ModelCatalog.Shared.Payload());
    }

    private ToolResult ManageProject(JsonElement args)
    {
        var action = ToolArgs.String(args, "action") ?? "list";
        var host = Host;
        if (action == "list")
        {
            var projects = host is null
                ? Array.Empty<object>()
                : new object[]
                {
                    new
                    {
                        projectId = host.ActiveTimelineId ?? host.ProjectName,
                        name = host.ProjectName,
                        path = host.PackagePath,
                        active = true,
                    },
                };
            return ToolResult.OkJson(new
            {
                projects,
                note = "Windows MCP binds to the frontmost open project.",
            });
        }
        if (action == "bind")
        {
            var id = ToolArgs.String(args, "projectId");
            if (id is null) return ToolResult.Error("projectId is required");
            if (host is null) return ToolResult.Error("No project is open.");
            return ToolResult.OkJson(new
            {
                ok = true,
                projectId = host.ActiveTimelineId ?? host.ProjectName,
                name = host.ProjectName,
                note = "Bound to the open project.",
            });
        }
        return ToolResult.Error("action must be list or bind");
    }

    private static ExportJob? FindJob(IReadOnlyList<ExportJob> jobs, string jobId)
        => jobs.FirstOrDefault(j => j.Id == jobId
            || j.Id.StartsWith(jobId, StringComparison.OrdinalIgnoreCase));

    private static object JobDto(ExportJob job) => new
    {
        jobId = job.Id,
        filename = job.Filename,
        outputPath = job.OutputPath,
        format = job.Format.ToString().ToLowerInvariant(),
        status = job.Status.ToString().ToLowerInvariant(),
        progress = job.Progress,
        error = job.Error,
        warnings = job.Warnings,
    };

    private static ExportResolution ParseResolution(string? raw) => (raw ?? "match").ToLowerInvariant() switch
    {
        "720p" => ExportResolution.R720p,
        "1080p" => ExportResolution.R1080p,
        "1440p" => ExportResolution.R1440p,
        "4k" or "2160p" => ExportResolution.R4k,
        _ => ExportResolution.MatchTimeline,
    };

    private static string Sanitize(string name)
    {
        foreach (var c in Path.GetInvalidFileNameChars())
            name = name.Replace(c, '_');
        return string.IsNullOrWhiteSpace(name) ? "export" : name;
    }
}
