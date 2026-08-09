use serde_json::{Value, json};

#[derive(Debug, Clone)]
pub struct ToolDefinition {
    pub name: &'static str,
    pub description: &'static str,
    pub input_schema: Value,
}

fn object(properties: Value, required: &[&str]) -> Value {
    let mut schema = json!({
        "type": "object",
        "properties": properties,
        "additionalProperties": false,
    });
    if !required.is_empty() {
        schema["required"] = json!(required);
    }
    schema
}

pub fn implemented_tools() -> Vec<ToolDefinition> {
    vec![
        ToolDefinition {
            name: "manage_project",
            description: "List, open, create, or close Palmier projects for this MCP session. action=list|open|create|close.",
            input_schema: object(
                json!({
                    "action": {"type": "string", "enum": ["list", "open", "create", "close"]},
                    "name": {"type": "string"},
                    "id": {"type": "string"},
                    "path": {"type": "string"},
                    "fps": {"type": "integer"},
                    "aspectRatio": {"type": "string"},
                    "quality": {"type": "string", "enum": ["720p", "1080p", "2K", "4K"]},
                }),
                &["action"],
            ),
        },
        ToolDefinition {
            name: "get_timeline",
            description: "Returns project settings, tracks, and clips for the active timeline. Call at session start before edits.",
            input_schema: object(
                json!({
                    "startFrame": {"type": "integer"},
                    "endFrame": {"type": "integer"},
                    "captionDetail": {"type": "boolean"},
                }),
                &[],
            ),
        },
        ToolDefinition {
            name: "create_timeline",
            description: "Creates a timeline and switches to it. Optional from duplicates an existing timelineId.",
            input_schema: object(
                json!({
                    "name": {"type": "string"},
                    "from": {"type": "string"},
                }),
                &[],
            ),
        },
        ToolDefinition {
            name: "set_active_timeline",
            description: "Switches the active timeline targeted by read and edit tools.",
            input_schema: object(
                json!({
                    "timelineId": {"type": "string"},
                }),
                &["timelineId"],
            ),
        },
        ToolDefinition {
            name: "set_project_settings",
            description: "Change the project's frame rate, resolution, or aspect ratio.",
            input_schema: object(
                json!({
                    "fps": {"type": "integer"},
                    "width": {"type": "integer"},
                    "height": {"type": "integer"},
                    "aspectRatio": {"type": "string"},
                    "quality": {"type": "string", "enum": ["720p", "1080p", "2K", "4K"]},
                }),
                &[],
            ),
        },
        ToolDefinition {
            name: "get_media",
            description: "Lists media assets, folders, and timelines. Asset ids are mediaRef values for other tools.",
            input_schema: object(
                json!({
                    "ids": {"type": "array", "items": {"type": "string"}},
                    "folder": {"type": "string"},
                    "pending": {"type": "boolean"},
                }),
                &[],
            ),
        },
        ToolDefinition {
            name: "import_media",
            description: "Imports external media into the project library from url, path, bytes, or matte.",
            input_schema: object(
                json!({
                    "source": {"type": "object"},
                    "name": {"type": "string"},
                    "folder": {"type": "string"},
                }),
                &["source"],
            ),
        },
        ToolDefinition {
            name: "organize_media",
            description: "Create folders, move, rename, or delete media library items in one action.",
            input_schema: object(
                json!({
                    "createFolders": {"type": "array", "items": {"type": "string"}},
                    "moves": {"type": "array"},
                    "renames": {"type": "array"},
                    "deletes": {"type": "array", "items": {"type": "string"}},
                }),
                &[],
            ),
        },
        ToolDefinition {
            name: "capture_frame",
            description: "Capture one video frame as a PNG media asset from the timeline or a source asset.",
            input_schema: object(
                json!({
                    "timelineFrame": {"type": "integer"},
                    "mediaRef": {"type": "string"},
                    "sourceSeconds": {"type": "number"},
                    "name": {"type": "string"},
                }),
                &[],
            ),
        },
        ToolDefinition {
            name: "add_clips",
            description: "Places one or more media assets on the timeline as a single undoable action.",
            input_schema: object(
                json!({
                    "entries": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "mediaRef": {"type": "string"},
                                "trackIndex": {"type": "integer"},
                                "startFrame": {"type": "integer"},
                                "endFrame": {"type": "integer"},
                                "source": {"type": "array", "items": {"type": "number"}},
                            },
                            "required": ["mediaRef", "startFrame"],
                        },
                    },
                }),
                &["entries"],
            ),
        },
        ToolDefinition {
            name: "insert_clips",
            description: "Inserts media at a point and ripples later clips right. Non-destructive counterpart to add_clips.",
            input_schema: object(
                json!({
                    "trackIndex": {"type": "integer"},
                    "atFrame": {"type": "integer"},
                    "entries": {"type": "array"},
                }),
                &["trackIndex", "atFrame", "entries"],
            ),
        },
        ToolDefinition {
            name: "move_clips",
            description: "Moves one or more clips to a new track and/or frame position.",
            input_schema: object(
                json!({
                    "moves": {"type": "array"},
                }),
                &["moves"],
            ),
        },
        ToolDefinition {
            name: "remove_clips",
            description: "Removes one or more clips by ID as a single undoable action.",
            input_schema: object(
                json!({
                    "clipIds": {"type": "array", "items": {"type": "string"}},
                }),
                &["clipIds"],
            ),
        },
        ToolDefinition {
            name: "split_clips",
            description: "Splits clips at cut points without shifting surrounding media.",
            input_schema: object(
                json!({
                    "splits": {"type": "array"},
                    "trackIndex": {"type": "integer"},
                    "frames": {"type": "array", "items": {"type": "integer"}},
                }),
                &[],
            ),
        },
        ToolDefinition {
            name: "ripple_delete_ranges",
            description: "Cuts ranges out and closes the gaps in one undoable action.",
            input_schema: object(
                json!({
                    "trackIndex": {"type": "integer"},
                    "clipId": {"type": "string"},
                    "ranges": {"type": "array"},
                    "units": {"type": "string", "enum": ["seconds", "frames"]},
                    "ignoreSyncLockedTracks": {"type": "array", "items": {"type": "integer"}},
                }),
                &["ranges"],
            ),
        },
        ToolDefinition {
            name: "manage_clip_links",
            description: "Links or unlinks clips without moving or trimming them.",
            input_schema: object(
                json!({
                    "action": {"type": "string", "enum": ["link", "unlink"]},
                    "clipIds": {"type": "array", "items": {"type": "string"}},
                }),
                &["action", "clipIds"],
            ),
        },
        ToolDefinition {
            name: "manage_tracks",
            description: "Reorders, configures, or removes tracks in one undoable action.",
            input_schema: object(
                json!({
                    "reorder": {"type": "array"},
                    "set": {"type": "array"},
                    "remove": {"type": "array"},
                }),
                &[],
            ),
        },
        ToolDefinition {
            name: "set_clip_properties",
            description: "Apply generic clip property values to one or more clips.",
            input_schema: object(
                json!({
                    "clipIds": {"type": "array", "items": {"type": "string"}},
                    "durationFrames": {"type": "integer"},
                    "trimStartFrame": {"type": "integer"},
                    "trimEndFrame": {"type": "integer"},
                    "speed": {"type": "number"},
                    "volumeDb": {"type": "number"},
                    "opacity": {"type": "number"},
                    "fadeInFrames": {"type": "integer"},
                    "fadeOutFrames": {"type": "integer"},
                    "edgeRounding": {"type": "number"},
                    "edgeSoftness": {"type": "number"},
                    "transform": {"type": "object"},
                    "blendMode": {"type": "string"},
                }),
                &["clipIds"],
            ),
        },
        ToolDefinition {
            name: "add_texts",
            description: "Adds text clips to the active timeline.",
            input_schema: object(
                json!({
                    "entries": {"type": "array"},
                }),
                &["entries"],
            ),
        },
        ToolDefinition {
            name: "update_text",
            description: "Updates text clip content or style. Prefer captionGroupId for caption restyles.",
            input_schema: object(
                json!({
                    "clipIds": {"type": "array", "items": {"type": "string"}},
                    "captionGroupId": {"type": "string"},
                    "content": {"type": "string"},
                    "transform": {"type": "object"},
                    "style": {"type": "object"},
                }),
                &[],
            ),
        },
        ToolDefinition {
            name: "apply_color",
            description: "Author or refine a color grade on video/image clips with named controls.",
            input_schema: object(
                json!({
                    "clipIds": {"type": "array", "items": {"type": "string"}},
                    "reset": {"type": "boolean"},
                    "color": {"type": "object"},
                    "exposure": {"type": "number"},
                    "contrast": {"type": "number"},
                    "saturation": {"type": "number"},
                    "temperature": {"type": "number"},
                    "tint": {"type": "number"},
                    "highlights": {"type": "number"},
                    "shadows": {"type": "number"},
                }),
                &["clipIds"],
            ),
        },
        ToolDefinition {
            name: "apply_effect",
            description: "Apply non-color effects to video/image clips as an editable effect stack.",
            input_schema: object(
                json!({
                    "clipIds": {"type": "array", "items": {"type": "string"}},
                    "effects": {"type": "array"},
                    "remove": {"type": "array", "items": {"type": "string"}},
                }),
                &["clipIds"],
            ),
        },
        ToolDefinition {
            name: "export_project",
            description: "Queues an export from the current project. Use manage_exports for progress or cancel.",
            input_schema: object(
                json!({
                    "mode": {"type": "string", "enum": ["video", "xml", "fcpxml", "palmier"]},
                    "codec": {"type": "string"},
                    "resolution": {"type": "string"},
                    "outputPath": {"type": "string"},
                    "overwrite": {"type": "boolean"},
                    "timelineId": {"type": "string"},
                }),
                &[],
            ),
        },
        ToolDefinition {
            name: "manage_exports",
            description: "Lists or cancels exports for the current project.",
            input_schema: object(
                json!({
                    "action": {"type": "string", "enum": ["list", "cancel"]},
                    "jobId": {"type": "string"},
                }),
                &["action"],
            ),
        },
        ToolDefinition {
            name: "list_models",
            description: "Lists configured Fal and Replicate generation models and whether each can run with the current Secret Service credentials.",
            input_schema: object(json!({}), &[]),
        },
        ToolDefinition {
            name: "generate_video",
            description: "Starts one cancellable video generation job using a configured BYOK model.",
            input_schema: object(
                json!({
                    "modelId": {"type": "string"},
                    "prompt": {"type": "string"},
                    "aspectRatio": {"type": "string"},
                    "duration": {"type": "integer"},
                    "referenceUrls": {"type": "array", "items": {"type": "string"}},
                }),
                &["modelId", "prompt"],
            ),
        },
        ToolDefinition {
            name: "generate_image",
            description: "Starts one cancellable image generation job using a configured BYOK model.",
            input_schema: object(
                json!({
                    "modelId": {"type": "string"},
                    "prompt": {"type": "string"},
                    "aspectRatio": {"type": "string"},
                    "referenceUrls": {"type": "array", "items": {"type": "string"}},
                    "numOutputs": {"type": "integer", "minimum": 1},
                }),
                &["modelId", "prompt"],
            ),
        },
        ToolDefinition {
            name: "generate_audio",
            description: "Starts one cancellable audio generation job using a configured BYOK model.",
            input_schema: object(
                json!({
                    "modelId": {"type": "string"},
                    "prompt": {"type": "string"},
                    "duration": {"type": "integer"},
                }),
                &["modelId", "prompt"],
            ),
        },
        ToolDefinition {
            name: "upscale_media",
            description: "Starts one cancellable upscale job for a media URL using a configured BYOK model.",
            input_schema: object(
                json!({
                    "modelId": {"type": "string"},
                    "sourceUrl": {"type": "string"},
                    "prompt": {"type": "string"},
                }),
                &["modelId", "sourceUrl"],
            ),
        },
        ToolDefinition {
            name: "undo",
            description: "Undoes the last undoable editor mutation for the active project.",
            input_schema: object(json!({}), &[]),
        },
    ]
}

pub fn tools_list_payload() -> Value {
    let tools: Vec<Value> = implemented_tools()
        .into_iter()
        .map(|tool| {
            json!({
                "name": tool.name,
                "description": tool.description,
                "inputSchema": tool.input_schema,
            })
        })
        .collect();
    json!({ "tools": tools })
}
