using System.Text.Json;
using PalmierPro.Cloud.Generation;
using PalmierPro.Core.Models;

namespace PalmierPro.Agent.Tools;

public sealed partial class ToolExecutor
{
    private static ToolResult Generate(IAgentEditorHost host, JsonElement args, GenerationKind kind)
    {
        var prompt = ToolArgs.String(args, "prompt") ?? "";
        if (kind != GenerationKind.Upscale && string.IsNullOrWhiteSpace(prompt))
            return ToolResult.Error("prompt is required");

        var wait = ToolArgs.Bool(args, "wait") ?? false;
        var model = ToolArgs.String(args, "model") ?? "default";
        var folderId = ToolArgs.String(args, "folder");
        // Gap placement (Windows + Mac UI parity path).
        var startFrame = ToolArgs.Int(args, "startFrame");
        var endFrame = ToolArgs.Int(args, "endFrame");
        // Mac conditioning: first/last frame image mediaRefs.
        var startFrameMediaRef = ToolArgs.String(args, "startFrameMediaRef");
        var endFrameMediaRef = ToolArgs.String(args, "endFrameMediaRef");
        var type = kind switch
        {
            GenerationKind.Image => ClipType.Image,
            GenerationKind.Audio => ClipType.Audio,
            _ => ClipType.Video,
        };
        var name = kind switch
        {
            GenerationKind.Image => "Generated Image",
            GenerationKind.Audio => "Generated Audio",
            GenerationKind.Upscale => "Upscaled Media",
            _ => "Generated Video",
        };

        var placeholder = host.CreatePendingGenerationAsset(name, type, prompt, model, null, folderId);

        var request = new GenerationSubmitRequest
        {
            Kind = kind,
            Model = model,
            Prompt = prompt,
            DurationSeconds = ToolArgs.Number(args, "durationSeconds"),
            Duration = ToolArgs.Int(args, "duration"),
            AspectRatio = ToolArgs.String(args, "aspectRatio"),
            Resolution = ToolArgs.String(args, "resolution"),
            SourceUrl = ToolArgs.String(args, "mediaRef")
                ?? ToolArgs.String(args, "sourceUrl")
                ?? ToolArgs.String(args, "sourceVideo"),
            Voice = ToolArgs.String(args, "voice"),
            Instrumental = ToolArgs.Bool(args, "instrumental") ?? false,
            NumImages = ToolArgs.Int(args, "numImages") ?? 1,
            ProjectId = host.ActiveTimelineId,
            StartFrame = startFrame,
            EndFrame = endFrame,
            StartFrameMediaRef = startFrameMediaRef,
            EndFrameMediaRef = endFrameMediaRef,
            SourceClipId = ToolArgs.String(args, "sourceClipId"),
        };

        GenerationJob job;
        try
        {
            job = GenerationClient.Shared.SubmitAsync(request).GetAwaiter().GetResult();
        }
        catch (Exception ex)
        {
            host.CompleteGenerationAsset(placeholder.Id, null, "failed", null);
            return ToolResult.Error(ex.Message);
        }

        if (job.Status == "failed")
        {
            host.CompleteGenerationAsset(placeholder.Id, null, "failed", null);
            return ToolResult.Error(job.Error ?? "Generation failed.");
        }

        // Stash job id on the placeholder.
        placeholder.ImportInput ??= new MediaImportInput();
        placeholder.ImportInput.SourceURL = job.Id;

        if (wait && !string.IsNullOrEmpty(job.Id))
            job = GenerationClient.Shared.WaitAsync(job.Id).GetAwaiter().GetResult();

        if (job.Status == "failed")
        {
            host.CompleteGenerationAsset(placeholder.Id, null, "failed", job.ResultUrls);
            return ToolResult.Error(job.Error ?? "Generation failed.");
        }

        if (job.Status is "succeeded" or "ready" || (job.ResultUrls?.Count ?? 0) > 0)
            host.CompleteGenerationAsset(placeholder.Id, null, "ready", job.ResultUrls);
        else
            host.CompleteGenerationAsset(placeholder.Id, null, job.Status ?? "queued", job.ResultUrls);

        string? gapClipId = null;
        string? gapNote = null;
        if (kind == GenerationKind.Video
            && startFrame is { } sf
            && endFrame is { } ef
            && ef > sf
            && host.EditOperations is { } ops
            && host.ActiveTimeline is { } timeline)
        {
            var trackIndex = ToolArgs.Int(args, "trackIndex")
                ?? DefaultTrackIndex(timeline, ClipType.Video);
            if (trackIndex < 0) trackIndex = 0;
            gapClipId = ops.PlaceAiGapFill(placeholder.Id, trackIndex, sf, ef, "AI transition placeholder");
            if (gapClipId is not null)
            {
                host.NotifyTimelineChanged();
                gapNote = "Pending AI transition clip placed across the gap; replaces when generation completes.";
            }
        }

        return ToolResult.OkJson(new Dictionary<string, object?>
        {
            ["mediaRef"] = placeholder.Id,
            ["jobId"] = job.Id,
            ["status"] = job.Status,
            ["generationStatus"] = placeholder.GenerationStatus,
            ["resultUrls"] = job.ResultUrls,
            ["costCredits"] = job.CostCredits,
            ["error"] = job.Error,
            ["gapFillClipId"] = gapClipId,
            ["note"] = gapNote
                ?? "Library placeholder created — poll get_media until generationStatus is ready, then add_clips.",
        });
    }
}
