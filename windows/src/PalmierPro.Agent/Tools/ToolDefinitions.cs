using System.Text.Json.Nodes;

namespace PalmierPro.Agent.Tools;

public sealed record AgentTool(ToolName Name, string Description, JsonObject InputSchema);

/// <summary>
/// Tool inventory shared by Anthropic chat and the MCP server. Names and parameter
/// shapes match Mac ToolDefinitions for contract stability.
/// </summary>
public static class ToolDefinitions
{
    public static IReadOnlyList<AgentTool> All { get; } = BuildAll();

    public static IReadOnlyList<AgentTool> McpServer { get; } =
    [
        .. All,
        new AgentTool(
            ToolName.ManageProject,
            "Bind this MCP session to an open project, or list open projects.",
            ObjectSchema(("action", S("list|bind")), ("projectId", S()))),
    ];

    private static IReadOnlyList<AgentTool> BuildAll()
    {
        var tools = new List<AgentTool>
        {
            T(ToolName.GetTimeline,
                "Always call at the start of a session. Returns settings, tracks (trackId/index), clips as " +
                "frames:[start,end), linked audio folded into audio:{}, gaps, captionGroups, canGenerate.",
                ObjectSchema(("startFrame", I("Optional window start")), ("endFrame", I("Optional window end")),
                    ("captionDetail", B("Expand caption groups")))),

            T(ToolName.InspectTimeline,
                "Render what the preview shows at a frame (composited layers). Use to verify edits landed.",
                ObjectSchema(("startFrame", I("Project frame")), ("endFrame", I("Optional sample end")),
                    ("maxFrames", I("Samples when endFrame set")))),

            T(ToolName.CreateTimeline,
                "Create an empty timeline or duplicate one (from) and switch to it.",
                ObjectSchema(("name", S("Timeline name")), ("from", S("Source timelineId to duplicate")))),

            T(ToolName.SetActiveTimeline,
                "Switch the active timeline. Re-read get_timeline afterward.",
                ObjectSchema(req: ["timelineId"], ("timelineId", S("Timeline id")))),

            T(ToolName.SetProjectSettings,
                "Update fps, width, height, aspectRatio, or quality on the active timeline.",
                ObjectSchema(("fps", N()), ("width", I()), ("height", I()), ("aspectRatio", S()), ("quality", S()))),

            T(ToolName.ExportProject,
                "Queue a background export (video/xml/fcpxml/palmier). ProRes/DNxHR/UtVideo refused — use h265+quality=mezzanine.",
                ObjectSchema(("mode", S("video|xml|fcpxml|palmier")),
                    ("codec", S("h264|h265|hevchdr|prores")),
                    ("quality", S("delivery|high|mezzanine")),
                    ("resolution", S("720p|1080p|1440p|4k|match")), ("outputPath", S()),
                    ("overwrite", B()), ("timelineId", S()))),

            T(ToolName.ManageExports,
                "List export jobs, read a job, or cancel by jobId.",
                ObjectSchema(("action", S("list|get|cancel")), ("jobId", S()))),

            T(ToolName.GetMedia,
                "List media library assets and timelines. Filter with ids, folder, or pending.",
                ObjectSchema(("ids", A(S())), ("folder", S()), ("pending", B()))),

            T(ToolName.InspectMedia,
                "Inspect a media asset: sample frames plus transcription (segments; optional wordTimestamps). " +
                "Never describe from filename alone. Pass clipId to map timing into project frames.",
                ObjectSchema(req: ["mediaRef"], ("mediaRef", S()), ("overview", B()),
                    ("startSeconds", N()), ("endSeconds", N()), ("maxFrames", I()),
                    ("wordTimestamps", B()), ("language", S()), ("clipId", S()))),

            T(ToolName.SearchMedia,
                "Search across spoken transcripts and/or visual frame embeddings. " +
                "Hits carry source second ranges for add_clips.",
                ObjectSchema(req: ["query"], ("query", S()), ("mediaRef", S()),
                    ("scope", S("spoken|visual|both")), ("limit", I()))),

            T(ToolName.ImportMedia,
                "Import files into the project library from paths, source.url (download), or source.bytes (base64).",
                ObjectSchema(("paths", A(S())), ("path", S()), ("folder", S()), ("source", O()))),

            T(ToolName.CaptureFrame,
                "Capture a still from the timeline or a media asset into the library.",
                ObjectSchema(("atFrame", I()), ("mediaRef", S()), ("atSeconds", N()))),

            T(ToolName.OrganizeMedia,
                "Move/rename media folders or assets. action=nest|unnest nests timeline clips into a sequence carrier.",
                ObjectSchema(("action", S("nest|unnest|…")), ("ids", A(S())), ("clipIds", A(S())),
                    ("folder", S()), ("name", S()),
                    ("createFolders", A(O())), ("moves", A(O())), ("renames", A(O())), ("deletes", A(S())))),

            T(ToolName.ManageTracks,
                "Add, remove, reorder, or set mute/hide/syncLock on tracks (action: add|remove|reorder|set|toggleMute|…).",
                ObjectSchema(("action", S()), ("trackId", S()), ("type", S("video|audio")),
                    ("index", I()), ("toIndex", I()), ("muted", B()), ("hidden", B()), ("syncLocked", B()))),

            T(ToolName.AddClips,
                "Overwrite-place clips on the active timeline.",
                ObjectSchema(req: ["entries"], ("entries", A(O())))),

            T(ToolName.InsertClips,
                "Ripple-insert clips at a frame, shifting later content.",
                ObjectSchema(req: ["entries"], ("trackIndex", I()), ("atFrame", I()), ("entries", A(O())))),

            T(ToolName.MoveClips,
                "Move clips to a track/frame.",
                ObjectSchema(req: ["moves"], ("moves", A(O())))),

            T(ToolName.RemoveClips,
                "Delete clips (leave gaps) or ripple-delete when ripple=true.",
                ObjectSchema(req: ["clipIds"], ("clipIds", A(S())), ("ripple", B()))),

            T(ToolName.SplitClips,
                "Split clips at frames. Does not remove content.",
                ObjectSchema(("splits", A(O())), ("trackIndex", I()), ("frames", A(I())))),

            T(ToolName.RippleDeleteRanges,
                "Ripple-delete frame ranges on a track.",
                ObjectSchema(("trackIndex", I()), ("ranges", A(A(I()))), ("clipId", S()),
                    ("ignoreSyncLockedTracks", B()))),

            T(ToolName.SetClipProperties,
                "Set opacity, volume, speed, fades, transform, crop, and related clip fields.",
                ObjectSchema(("clipIds", A(S())), ("opacity", N()), ("volumeDb", N()), ("speed", N()),
                    ("fadeInFrames", I()), ("fadeOutFrames", I()), ("transform", O()), ("crop", O()))),

            T(ToolName.SetKeyframes,
                "Replace keyframes for one animatable property on a clip.",
                ObjectSchema(req: ["clipId"], ("clipId", S()), ("property", S()), ("keyframes", A(O())))),

            T(ToolName.ApplyLayout,
                "Compose split-screen / PIP / grid layouts.",
                ObjectSchema(req: ["layout"], ("layout", S()), ("slots", A(O())),
                    ("startFrame", I()), ("endFrame", I()), ("fit", S()))),

            T(ToolName.SyncClips,
                "Align clips by waveform (auto|audio) or report timecode unavailable (timecode).",
                ObjectSchema(("referenceClipId", S()), ("targetClipIds", A(S())), ("clipIds", A(S())),
                    ("mode", S("auto|audio|timecode")), ("method", S("alias for mode")),
                    ("searchWindowSeconds", N()), ("minConfidence", N()))),

            T(ToolName.Undo,
                "Undo or redo the last editor action.",
                ObjectSchema(("action", S("undo|redo")))),

            T(ToolName.ManageMulticam,
                "Create, dissolve, or edit multicam groups.",
                ObjectSchema(("action", S()), ("groupId", S()), ("clipIds", A(S())), ("name", S()))),

            T(ToolName.ChangeCam,
                "Switch multicam angle, batch entries[{range,angle}], or multi-angle layout+angles overlay.",
                ObjectSchema(("clipIds", A(S())), ("angle", S()), ("groupId", S()),
                    ("layout", S()), ("angles", A(S())), ("startFrame", I()), ("endFrame", I()),
                    ("entries", A(O())))),

            T(ToolName.GetMulticam,
                "List multicam groups and angles.",
                ObjectSchema(("groupId", S()))),

            T(ToolName.GetTranscript,
                "Default: walk the active timeline into global project-frame word indices (Mac contract). " +
                "Optional mediaRef for a single asset; storageId/jobId for cloud.",
                ObjectSchema(("clipId", S()), ("startFrame", I()), ("endFrame", I()),
                    ("granularity", S("words|segments")), ("language", S()),
                    ("mediaRef", S()), ("storageId", S()), ("jobId", S()), ("preferLocal", B()))),

            T(ToolName.RemoveWords,
                "Ripple-remove spoken words by get_transcript indices (words or matches). Returns a mutation delta.",
                ObjectSchema(("words", A(O())), ("matches", A(S())),
                    ("cutAggressiveness", S("tight|balanced|loose")), ("language", S()))),

            T(ToolName.RemoveSilence,
                "Detect and ripple-remove silence / dead air.",
                ObjectSchema(("clipIds", A(S())), ("thresholdDb", N()), ("minGapSeconds", N()))),

            T(ToolName.DetectBeats,
                "Detect musical beats on an audio asset (source seconds).",
                ObjectSchema(req: ["mediaRef"], ("mediaRef", S()))),

            T(ToolName.AddTexts,
                "Add text / title overlays on a video track.",
                ObjectSchema(req: ["entries"], ("entries", A(O())))),

            T(ToolName.UpdateText,
                "Update text content or style; use captionGroupId to restyle a caption group.",
                ObjectSchema(("clipId", S()), ("captionGroupId", S()), ("text", S()), ("style", O()))),

            T(ToolName.AddCaptions,
                "Transcribe timeline speech into caption clips.",
                ObjectSchema(("style", O()), ("language", S()))),

            T(ToolName.ApplyColor,
                "Apply or copy a color grade.",
                ObjectSchema(req: ["clipIds"], ("clipIds", A(S())), ("color", O()))),

            T(ToolName.ApplyEffect,
                "Add or remove effect stack entries (type + params).",
                ObjectSchema(("clipIds", A(S())), ("effects", A(O())), ("remove", A(S())))),

            T(ToolName.InspectColor,
                "Inspect grade / scopes for a clip or media frame.",
                ObjectSchema(("clipId", S()), ("mediaRef", S()), ("atFrame", I()), ("reference", S()))),

            T(ToolName.DenoiseAudio,
                "Enable or tune audio denoise on clips.",
                ObjectSchema(("clipIds", A(S())), ("strength", N()), ("enabled", B()))),

            T(ToolName.ListModels, "List available generation models and credit status.", ObjectSchema()),

            T(ToolName.GenerateVideo,
                "Cloud video generation into the library. Requires canGenerate. " +
                "Optional startFrameMediaRef/endFrameMediaRef seed first/last frames. " +
                "Optional startFrame+endFrame+trackIndex places a pending AI gap-fill clip.",
                ObjectSchema(req: ["prompt"],
                    ("prompt", S()), ("model", S()), ("duration", I()), ("durationSeconds", N()),
                    ("aspectRatio", S()), ("resolution", S()), ("folder", S()), ("wait", B()),
                    ("startFrameMediaRef", S()), ("endFrameMediaRef", S()),
                    ("sourceVideo", S()), ("sourceClipId", S()), ("mediaRef", S()),
                    ("startFrame", I()), ("endFrame", I()), ("trackIndex", I()))),

            T(ToolName.GenerateImage,
                "Cloud image generation into the library. Requires canGenerate.",
                ObjectSchema(req: ["prompt"],
                    ("prompt", S()), ("model", S()), ("aspectRatio", S()), ("resolution", S()),
                    ("folder", S()), ("numImages", I()), ("wait", B()))),

            T(ToolName.GenerateAudio,
                "Cloud audio / speech generation into the library. Requires canGenerate.",
                ObjectSchema(req: ["prompt"],
                    ("prompt", S()), ("model", S()), ("voice", S()), ("instrumental", B()),
                    ("folder", S()), ("wait", B()))),

            T(ToolName.UpscaleMedia,
                "Cloud upscale of a media asset. Requires canGenerate.",
                ObjectSchema(req: ["mediaRef"],
                    ("mediaRef", S()), ("scale", N()), ("model", S()), ("wait", B()))),

            T(ToolName.SendFeedback,
                "Send product feedback from the agent session.",
                ObjectSchema(req: ["message"], ("message", S()))),

            T(ToolName.ReadSkill,
                "Read a skill document by id from the skill store.",
                ObjectSchema(req: ["skillId"], ("skillId", S()))),
        };
        return tools;
    }

    private static AgentTool T(ToolName name, string description, JsonObject schema)
        => new(name, description, schema);

    private static JsonObject ObjectSchema(
        string[]? req = null,
        params (string Key, JsonObject Schema)[] properties)
    {
        var props = new JsonObject();
        foreach (var (key, schema) in properties)
            props[key] = schema;
        var root = new JsonObject
        {
            ["type"] = "object",
            ["properties"] = props,
            ["additionalProperties"] = false,
        };
        if (req is { Length: > 0 })
        {
            var arr = new JsonArray();
            foreach (var key in req) arr.Add(key);
            root["required"] = arr;
        }
        return root;
    }

    private static JsonObject ObjectSchema(params (string Key, JsonObject Schema)[] properties)
        => ObjectSchema(null, properties);

    private static JsonObject S(string? d = null) => Typed("string", d);
    private static JsonObject I(string? d = null) => Typed("integer", d);
    private static JsonObject N(string? d = null) => Typed("number", d);
    private static JsonObject B(string? d = null) => Typed("boolean", d);
    private static JsonObject O(string? d = null) => Typed("object", d);

    private static JsonObject A(JsonObject items)
        => new() { ["type"] = "array", ["items"] = items };

    private static JsonObject Typed(string type, string? description)
    {
        var n = new JsonObject { ["type"] = type };
        if (description is not null) n["description"] = description;
        return n;
    }
}
