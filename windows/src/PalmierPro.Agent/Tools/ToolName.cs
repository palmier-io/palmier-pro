namespace PalmierPro.Agent.Tools;

/// <summary>Stable MCP / Anthropic tool names — must match Mac ToolName raw values.</summary>
public enum ToolName
{
    ManageProject,
    GetTimeline,
    InspectTimeline,
    CreateTimeline,
    SetActiveTimeline,
    SetProjectSettings,
    ExportProject,
    ManageExports,
    GetMedia,
    InspectMedia,
    SearchMedia,
    ImportMedia,
    CaptureFrame,
    OrganizeMedia,
    ManageTracks,
    AddClips,
    InsertClips,
    MoveClips,
    RemoveClips,
    SplitClips,
    RippleDeleteRanges,
    SetClipProperties,
    SetKeyframes,
    ApplyLayout,
    SyncClips,
    Undo,
    ManageMulticam,
    ChangeCam,
    GetMulticam,
    GetTranscript,
    RemoveWords,
    RemoveSilence,
    DetectBeats,
    AddTexts,
    UpdateText,
    AddCaptions,
    ApplyColor,
    ApplyEffect,
    InspectColor,
    DenoiseAudio,
    ListModels,
    GenerateVideo,
    GenerateImage,
    GenerateAudio,
    UpscaleMedia,
    SendFeedback,
    ReadSkill,
}

public static class ToolNameExtensions
{
    public static string ApiName(this ToolName name) => name switch
    {
        ToolName.ManageProject => "manage_project",
        ToolName.GetTimeline => "get_timeline",
        ToolName.InspectTimeline => "inspect_timeline",
        ToolName.CreateTimeline => "create_timeline",
        ToolName.SetActiveTimeline => "set_active_timeline",
        ToolName.SetProjectSettings => "set_project_settings",
        ToolName.ExportProject => "export_project",
        ToolName.ManageExports => "manage_exports",
        ToolName.GetMedia => "get_media",
        ToolName.InspectMedia => "inspect_media",
        ToolName.SearchMedia => "search_media",
        ToolName.ImportMedia => "import_media",
        ToolName.CaptureFrame => "capture_frame",
        ToolName.OrganizeMedia => "organize_media",
        ToolName.ManageTracks => "manage_tracks",
        ToolName.AddClips => "add_clips",
        ToolName.InsertClips => "insert_clips",
        ToolName.MoveClips => "move_clips",
        ToolName.RemoveClips => "remove_clips",
        ToolName.SplitClips => "split_clips",
        ToolName.RippleDeleteRanges => "ripple_delete_ranges",
        ToolName.SetClipProperties => "set_clip_properties",
        ToolName.SetKeyframes => "set_keyframes",
        ToolName.ApplyLayout => "apply_layout",
        ToolName.SyncClips => "sync_clips",
        ToolName.Undo => "undo",
        ToolName.ManageMulticam => "manage_multicam",
        ToolName.ChangeCam => "change_cam",
        ToolName.GetMulticam => "get_multicam",
        ToolName.GetTranscript => "get_transcript",
        ToolName.RemoveWords => "remove_words",
        ToolName.RemoveSilence => "remove_silence",
        ToolName.DetectBeats => "detect_beats",
        ToolName.AddTexts => "add_texts",
        ToolName.UpdateText => "update_text",
        ToolName.AddCaptions => "add_captions",
        ToolName.ApplyColor => "apply_color",
        ToolName.ApplyEffect => "apply_effect",
        ToolName.InspectColor => "inspect_color",
        ToolName.DenoiseAudio => "denoise_audio",
        ToolName.ListModels => "list_models",
        ToolName.GenerateVideo => "generate_video",
        ToolName.GenerateImage => "generate_image",
        ToolName.GenerateAudio => "generate_audio",
        ToolName.UpscaleMedia => "upscale_media",
        ToolName.SendFeedback => "send_feedback",
        ToolName.ReadSkill => "read_skill",
        _ => throw new ArgumentOutOfRangeException(nameof(name)),
    };

    public static bool TryParse(string apiName, out ToolName name)
    {
        foreach (ToolName value in Enum.GetValues<ToolName>())
        {
            if (value.ApiName() == apiName)
            {
                name = value;
                return true;
            }
        }
        name = default;
        return false;
    }
}
