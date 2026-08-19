using System.Text.Json;
using PalmierPro.Core.Serialization;

namespace PalmierPro.Agent.Tools;

public sealed partial class ToolExecutor
{
    private static ToolResult SendFeedback(IAgentEditorHost host, JsonElement args)
    {
        var message = ToolArgs.String(args, "message");
        if (string.IsNullOrWhiteSpace(message))
            return ToolResult.Error("message is required");

        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PalmierPro", "feedback");
        Directory.CreateDirectory(dir);
        var id = Uuid.NewString();
        var path = Path.Combine(dir, $"{DateTime.UtcNow:yyyyMMdd-HHmmss}-{id[..8]}.json");
        var payload = new Dictionary<string, object?>
        {
            ["id"] = id,
            ["createdAt"] = DateTime.UtcNow.ToString("o"),
            ["message"] = message.Trim(),
            ["source"] = ToolArgs.String(args, "source") ?? "agent",
            ["projectName"] = host.ProjectName,
            ["timelineId"] = host.ActiveTimelineId,
        };
        File.WriteAllText(path, JsonSerializer.Serialize(payload, new JsonSerializerOptions
        {
            WriteIndented = true,
        }));
        return ToolResult.OkJson(new
        {
            ok = true,
            feedbackId = id,
            path,
            note = "Feedback written to LocalAppData/PalmierPro/feedback/.",
        });
    }
}
