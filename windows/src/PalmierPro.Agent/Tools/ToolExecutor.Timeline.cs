using System.Text.Json;
using PalmierPro.Core.Models;

namespace PalmierPro.Agent.Tools;

public sealed partial class ToolExecutor
{
    private static ToolResult GetTimeline(IAgentEditorHost host, JsonElement args)
    {
        var timeline = host.ActiveTimeline;
        if (timeline is null)
            return ToolResult.Error("No active timeline.");

        var start = ToolArgs.Int(args, "startFrame");
        var end = ToolArgs.Int(args, "endFrame");
        if (start is not null || end is not null)
        {
            var s = start ?? 0;
            var e = end ?? int.MaxValue;
            if (s >= e)
                return ToolResult.Error($"Invalid window [{s}, {e}): startFrame must be less than endFrame");
        }

        var captionDetail = ToolArgs.Bool(args, "captionDetail") ?? false;
        return ToolResult.OkJson(TimelineReceipt.Build(host, start, end, captionDetail));
    }

    private static ToolResult CreateTimeline(IAgentEditorHost host, JsonElement args)
    {
        var name = ToolArgs.String(args, "name");
        var from = ToolArgs.String(args, "from");
        string id;
        string note;
        if (from is not null)
        {
            id = host.DuplicateTimeline(from, name);
            note = "Duplicated timeline is active; clip/track ids are new — re-read get_timeline.";
        }
        else
        {
            id = host.CreateTimeline(name);
            note = "Empty and now active; all edit tools target it.";
        }
        var created = host.Timelines.FirstOrDefault(t => t.Id == id);
        return ToolResult.OkJson(new
        {
            timelineId = id,
            name = created?.Name ?? "",
            active = true,
            note,
        });
    }

    private static ToolResult SetActiveTimeline(IAgentEditorHost host, JsonElement args)
    {
        var id = ToolArgs.String(args, "timelineId");
        if (id is null) return ToolResult.Error("timelineId is required");
        var target = host.Timelines.FirstOrDefault(t => t.Id == id || t.Id.StartsWith(id, StringComparison.Ordinal));
        if (target is null)
            return ToolResult.Error($"No timeline with id '{id}'. get_media lists the project's timelines.");
        var already = host.ActiveTimelineId == target.Id;
        if (!already) host.SetActiveTimeline(target.Id);
        return ToolResult.OkJson(new
        {
            timelineId = target.Id,
            name = target.Name,
            active = true,
            totalFrames = target.TotalFrames,
            fps = target.Fps,
            trackCount = target.Tracks.Count,
            note = already
                ? "Already the active timeline."
                : "Re-read get_timeline — clip and track ids from the previous timeline no longer apply.",
        });
    }
}
