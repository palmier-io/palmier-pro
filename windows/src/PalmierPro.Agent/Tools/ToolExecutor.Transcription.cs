using System.Text.Json;
using PalmierPro.Cloud.Transcription;
using PalmierPro.Core.Editing;
using PalmierPro.Core.Models;
using PalmierPro.Core.Serialization;
using PalmierPro.Core.Transcription;

namespace PalmierPro.Agent.Tools;

public sealed partial class ToolExecutor
{
    private static ToolResult GetTranscript(IAgentEditorHost host, JsonElement args)
    {
        var jobId = ToolArgs.String(args, "jobId");
        var storageId = ToolArgs.String(args, "storageId");
        var language = ToolArgs.String(args, "language");
        var wait = ToolArgs.Bool(args, "wait") ?? true;
        var duration = ToolArgs.Number(args, "durationSeconds");
        var mediaRef = ToolArgs.String(args, "mediaRef");
        var clipId = ToolArgs.String(args, "clipId");
        var startFrame = ToolArgs.Int(args, "startFrame");
        var endFrame = ToolArgs.Int(args, "endFrame");
        var granularity = (ToolArgs.String(args, "granularity") ?? "words").ToLowerInvariant();

        if (!string.IsNullOrEmpty(jobId))
        {
            if (wait)
            {
                var done = TranscriptionClient.Shared
                    .WaitAndFetchResultAsync(jobId).GetAwaiter().GetResult();
                return StoreCloudTranscript(host, done, mediaRef ?? "cloud");
            }
            var job = TranscriptionClient.Shared.GetJobAsync(jobId).GetAwaiter().GetResult();
            return ToolResult.OkJson(new
            {
                jobId = job.Id,
                status = job.Status,
                error = job.Error,
            });
        }

        if (!string.IsNullOrEmpty(storageId))
        {
            if (duration is null or <= 0)
                return ToolResult.Error("durationSeconds is required with storageId.");
            var submitted = TranscriptionClient.Shared
                .SubmitAsync(storageId, duration.Value, language, host.ActiveTimelineId)
                .GetAwaiter().GetResult();
            if (submitted.Status == "failed")
                return ToolResult.Error(submitted.Error ?? "Transcription submit failed.");
            if (!wait)
                return ToolResult.OkJson(new { jobId = submitted.Id, status = submitted.Status });
            var done = TranscriptionClient.Shared
                .WaitAndFetchResultAsync(submitted.Id).GetAwaiter().GetResult();
            return StoreCloudTranscript(host, done, mediaRef ?? "cloud");
        }

        // Legacy single-asset path when mediaRef is explicit.
        if (!string.IsNullOrEmpty(mediaRef))
        {
            var path = ResolveMediaPath(host, mediaRef);
            if (path is null) return ToolResult.Error($"Media file not on disk: {mediaRef}");
            var fpsAsset = Math.Max(1, host.ActiveTimeline?.Fps ?? 30);
            try
            {
                var doc = LocalStt.TranscribeFile(path, mediaRef, fpsAsset, language);
                TranscriptCache.Shared.Store(host.PackagePath, doc);
                return ToolResult.OkJson(LegacyTranscriptPayload(doc));
            }
            catch (Exception ex)
            {
                return ToolResult.Error($"Local transcription failed: {ex.Message}");
            }
        }

        // Default: Mac timeline walk with global project-frame word indices.
        if (host.ActiveTimeline is null)
            return ToolResult.Error("No active timeline.");

        try
        {
            var built = TimelineTranscript.Build(host, language, clipId);
            if (built is null || built.Document.Words.Count == 0)
                return ToolResult.Error("No transcribable audio/video clips on the active timeline.");
            TranscriptCache.Shared.Store(host.PackagePath, built.Document);
            var fps = Math.Max(1, host.ActiveTimeline.Fps);
            return ToolResult.OkJson(TimelineTranscript.ResponsePayload(
                built, fps, startFrame, endFrame, granularity, clipId));
        }
        catch (Exception ex)
        {
            return ToolResult.Error($"Timeline transcription failed: {ex.Message}");
        }
    }

    private static ToolResult StoreCloudTranscript(
        IAgentEditorHost host, TranscriptionJob job, string mediaRef)
    {
        if (job.Status == "failed")
            return ToolResult.Error(job.Error ?? "Transcription failed.");
        var result = job.Result;
        if (result is null)
            return ToolResult.OkJson(new { jobId = job.Id, status = job.Status });

        var fps = Math.Max(1, host.ActiveTimeline?.Fps ?? 30);
        var words = new List<TranscriptWord>();
        var index = 0;
        foreach (var w in result.Words)
        {
            var start = (int)Math.Round((w.Start ?? 0) * fps);
            var end = (int)Math.Round((w.End ?? (w.Start ?? 0) + 0.1) * fps);
            words.Add(new TranscriptWord
            {
                Text = w.Text,
                StartFrame = start,
                EndFrame = Math.Max(start + 1, end),
                Index = index++,
                Speaker = w.Speaker,
            });
        }
        var segments = result.Segments.Select(s => new TranscriptSegment
        {
            Text = s.Text,
            StartFrame = (int)Math.Round(s.Start * fps),
            EndFrame = Math.Max(1, (int)Math.Round(s.End * fps)),
            Speaker = s.Speaker,
        }).ToList();

        var doc = new TranscriptDocument
        {
            MediaRef = mediaRef,
            Source = "cloud",
            Language = result.Language,
            Text = result.Text,
            Words = words,
            Segments = segments,
        };
        TranscriptCache.Shared.Store(host.PackagePath, doc);
        return ToolResult.OkJson(LegacyTranscriptPayload(doc, job.Id));
    }

    private static object LegacyTranscriptPayload(TranscriptDocument doc, string? jobId = null) => new
    {
        jobId,
        mediaRef = doc.MediaRef,
        transcriptionSource = doc.Source,
        language = doc.Language,
        text = doc.Text,
        words = doc.Words.Select(w => new
        {
            index = w.Index,
            text = w.Text,
            startFrame = w.StartFrame,
            endFrame = w.EndFrame,
            speaker = w.Speaker,
            clipId = w.ClipId,
        }).ToList(),
        segments = doc.Segments.Select(s => new
        {
            text = s.Text,
            startFrame = s.StartFrame,
            endFrame = s.EndFrame,
            speaker = s.Speaker,
        }).ToList(),
        note = doc.Source switch
        {
            "whisper" => "On-device Whisper transcription.",
            "local" =>
                "Whisper model not loaded; using energy VAD segment placeholders. " +
                "Set PALMIER_WHISPER_MODEL or place ggml-*.bin under models/.",
            _ => null,
        },
    };

    private static ToolResult AddCaptions(IAgentEditorHost host, JsonElement args)
    {
        var ops = host.EditOperations;
        var timeline = host.ActiveTimeline;
        if (ops is null || timeline is null) return ToolResult.Error("No active timeline.");

        var snapshot = MutationDelta.Snapshot(timeline);
        var doc = TranscriptCache.Shared.Get(host.PackagePath);
        if (doc is null || doc.Segments.Count == 0)
        {
            // Build timeline transcript if missing.
            var built = TimelineTranscript.Build(host, ToolArgs.String(args, "language"), null);
            if (built is null || built.Document.Segments.Count == 0)
                return ToolResult.Error("No transcript available. Call get_transcript first.");
            doc = built.Document;
            TranscriptCache.Shared.Store(host.PackagePath, doc);
        }

        var trackIndex = -1;
        for (var t = 0; t < timeline.Tracks.Count; t++)
        {
            if (ClipType.Text.IsCompatible(timeline.Tracks[t].Type))
            {
                trackIndex = t;
                break;
            }
        }
        if (trackIndex < 0)
            trackIndex = ops.InsertTrack(0, ClipType.Video);

        var groupId = Uuid.NewString();
        var style = new TextStyle();
        var transform = Transform.FromCenter(0.5, 0.85, 0.9, 0.2);
        var specs = doc.Segments.Select(seg => new TextClipSpec(
            trackIndex,
            seg.StartFrame,
            Math.Max(1, seg.EndFrame - seg.StartFrame),
            seg.Text,
            style,
            transform)).ToList();
        var ids = ops.PlaceTextClips(specs);
        ops.StampCaptionGroup(ids, groupId);
        host.NotifyTimelineChanged();
        var start = ids.Count == 0 ? 0 : doc.Segments.Min(s => s.StartFrame);
        var end = ids.Count == 0 ? 0 : doc.Segments.Max(s => s.EndFrame);
        return MutationDelta.Result(host, snapshot, ids, new Dictionary<string, object?>
        {
            ["captionGroupId"] = groupId,
            ["clipCount"] = ids.Count,
            ["frameRange"] = new[] { start, end },
            ["textPreview"] = string.Join(" ", doc.Segments.Take(3).Select(s => s.Text)),
        });
    }
}
