using System.Text.Json;

namespace PalmierPro.Agent.Tools;

/// <summary>
/// Shared by in-app agent chat and the MCP server. Tool bodies live in partial files.
/// </summary>
public sealed partial class ToolExecutor
{
    private readonly Func<IAgentEditorHost?> _hostProvider;
    private IAgentEditorHost? _boundHost;

    public ToolExecutor(IAgentEditorHost host)
    {
        _hostProvider = () => host;
        _boundHost = host;
    }

    public ToolExecutor(Func<IAgentEditorHost?> hostProvider)
    {
        _hostProvider = hostProvider;
        _boundHost = hostProvider();
    }

    public void BindHost(IAgentEditorHost? host) => _boundHost = host;

    private IAgentEditorHost? Host => _boundHost ?? _hostProvider();

    public Task<ToolResult> ExecuteAsync(string name, JsonElement args, string source = "agent")
    {
        if (!ToolNameExtensions.TryParse(name, out var tool))
            return Task.FromResult(ToolResult.Error($"Unknown tool: {name}"));

        try
        {
            return Task.FromResult(Execute(tool, args, source));
        }
        catch (Exception ex)
        {
            return Task.FromResult(ToolResult.Error(ex.Message));
        }
    }

    public Task<ToolResult> ExecuteAsync(string name, string argsJson, string source = "agent")
    {
        using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(argsJson) ? "{}" : argsJson);
        return ExecuteAsync(name, doc.RootElement.Clone(), source);
    }

    private ToolResult Execute(ToolName tool, JsonElement args, string source)
    {
        if (tool == ToolName.ManageProject)
            return ManageProject(args);

        var host = Host;
        if (host is null)
            return ToolResult.Error("No project is open. Open a project in Palmier Pro first.");

        return tool switch
        {
            ToolName.GetTimeline => GetTimeline(host, args),
            ToolName.CreateTimeline => CreateTimeline(host, args),
            ToolName.SetActiveTimeline => SetActiveTimeline(host, args),
            ToolName.SetProjectSettings => SetProjectSettings(host, args),
            ToolName.GetMedia => GetMedia(host, args),
            ToolName.RemoveClips => RemoveClips(host, args),
            ToolName.SplitClips => SplitClips(host, args),
            ToolName.AddClips => AddClips(host, args),
            ToolName.InsertClips => InsertClips(host, args),
            ToolName.MoveClips => MoveClips(host, args),
            ToolName.RippleDeleteRanges => RippleDeleteRanges(host, args),
            ToolName.ApplyEffect => ApplyEffect(host, args),
            ToolName.ApplyColor => ApplyColor(host, args),
            ToolName.ApplyLayout => ApplyLayout(host, args),
            ToolName.SetKeyframes => SetKeyframes(host, args),
            ToolName.AddTexts => AddTexts(host, args),
            ToolName.InspectTimeline => InspectTimeline(host, args),
            ToolName.GetMulticam => GetMulticam(host, args),
            ToolName.ChangeCam => ChangeCam(host, args),
            ToolName.ManageMulticam => ManageMulticam(host, args),
            ToolName.Undo => Undo(host, args),
            ToolName.ExportProject => ExportProject(host, args),
            ToolName.ManageExports => ManageExports(host, args),
            ToolName.ManageTracks => ManageTracks(host, args),
            ToolName.SetClipProperties => SetClipProperties(host, args),
            ToolName.ListModels => ListModels(host),
            ToolName.ReadSkill => ReadSkill(args),
            ToolName.SendFeedback => SendFeedback(host, args),
            ToolName.InspectMedia => InspectMedia(host, args),
            ToolName.SearchMedia => SearchMedia(host, args),
            ToolName.ImportMedia => ImportMedia(host, args),
            ToolName.CaptureFrame => CaptureFrame(host, args),
            ToolName.OrganizeMedia => OrganizeMedia(host, args),
            ToolName.SyncClips => SyncClips(host, args),
            ToolName.UpdateText => UpdateText(host, args),
            ToolName.InspectColor => InspectColor(host, args),
            ToolName.GenerateVideo => Generate(host, args, PalmierPro.Cloud.Generation.GenerationKind.Video),
            ToolName.GenerateImage => Generate(host, args, PalmierPro.Cloud.Generation.GenerationKind.Image),
            ToolName.GenerateAudio => Generate(host, args, PalmierPro.Cloud.Generation.GenerationKind.Audio),
            ToolName.UpscaleMedia => Generate(host, args, PalmierPro.Cloud.Generation.GenerationKind.Upscale),
            ToolName.GetTranscript => GetTranscript(host, args),
            ToolName.RemoveWords => RemoveWords(host, args),
            ToolName.RemoveSilence => RemoveSilence(host, args),
            ToolName.DetectBeats => DetectBeats(host, args),
            ToolName.AddCaptions => AddCaptions(host, args),
            ToolName.DenoiseAudio => DenoiseAudio(host, args),
            _ => ToolResult.Error($"{tool.ApiName()} is registered but not yet implemented on Windows."),
        };
    }
}
