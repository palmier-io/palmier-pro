use serde_json::{Value, json};

use crate::backend::{CreateProjectRequest, ProjectSelector, SharedBackend};
use crate::error::{BackendError, BackendResult};
use crate::json_util::{optional_string, require_object, require_string};
use crate::short_id::{expand_args, shorten_value};
use crate::tools::definitions::implemented_tools;

pub async fn call_tool(backend: &SharedBackend, name: &str, arguments: Value) -> Value {
    match call_tool_inner(backend, name, arguments).await {
        Ok(mut value) => {
            if let Ok(universe) = backend.id_universe().await {
                shorten_value(&mut value, &universe);
            }
            json!({
                "content": [{ "type": "text", "text": value.to_string() }],
                "structuredContent": value,
                "isError": false,
            })
        }
        Err(error) => {
            let payload = error.to_json();
            json!({
                "content": [{ "type": "text", "text": payload.to_string() }],
                "structuredContent": payload,
                "isError": true,
            })
        }
    }
}

async fn call_tool_inner(
    backend: &SharedBackend,
    name: &str,
    arguments: Value,
) -> BackendResult<Value> {
    if !implemented_tools().iter().any(|tool| tool.name == name) {
        return Err(BackendError::message(format!("unknown tool '{name}'")));
    }

    let requires_project = !matches!(name, "manage_project" | "list_models");
    if requires_project && !backend.has_active_project().await {
        return Err(BackendError::InactiveProject);
    }

    let args = if requires_project {
        let universe = backend.id_universe().await?;
        expand_args(&arguments, &universe)?
    } else {
        arguments
    };

    match name {
        "manage_project" => manage_project(backend, args).await,
        "get_timeline" => backend.get_timeline(args).await,
        "create_timeline" => backend.create_timeline(args).await,
        "set_active_timeline" => backend.set_active_timeline(args).await,
        "set_project_settings" => backend.set_project_settings(args).await,
        "get_media" => backend.get_media(args).await,
        "import_media" => backend.import_media(args).await,
        "organize_media" => backend.organize_media(args).await,
        "capture_frame" => backend.capture_frame(args).await,
        "add_clips" => backend.add_clips(args).await,
        "insert_clips" => backend.insert_clips(args).await,
        "move_clips" => backend.move_clips(args).await,
        "remove_clips" => backend.remove_clips(args).await,
        "split_clips" => backend.split_clips(args).await,
        "ripple_delete_ranges" => backend.ripple_delete_ranges(args).await,
        "manage_clip_links" => backend.manage_clip_links(args).await,
        "manage_tracks" => backend.manage_tracks(args).await,
        "set_clip_properties" => backend.set_clip_properties(args).await,
        "add_texts" => backend.add_texts(args).await,
        "update_text" => backend.update_text(args).await,
        "apply_color" => backend.apply_color(args).await,
        "apply_effect" => backend.apply_effect(args).await,
        "export_project" => backend.export_project(args).await,
        "manage_exports" => backend.manage_exports(args).await,
        "list_models" => backend.list_models(args).await,
        "generate_video" => backend.generate_video(args).await,
        "generate_image" => backend.generate_image(args).await,
        "generate_audio" => backend.generate_audio(args).await,
        "upscale_media" => backend.upscale_media(args).await,
        "undo" => backend.undo(args).await,
        other => Err(BackendError::message(format!("unknown tool '{other}'"))),
    }
}

async fn manage_project(backend: &SharedBackend, args: Value) -> BackendResult<Value> {
    let map = require_object(&args)?;
    let action = require_string(map, "action")?;
    match action.as_str() {
        "list" => backend.list_projects().await,
        "open" => {
            backend
                .open_project(ProjectSelector {
                    name: optional_string(map, "name")?,
                    id: optional_string(map, "id")?,
                    path: optional_string(map, "path")?,
                })
                .await
        }
        "create" => {
            backend
                .create_project(CreateProjectRequest {
                    name: optional_string(map, "name")?,
                    fps: map
                        .get("fps")
                        .and_then(Value::as_i64)
                        .map(|value| value as i32),
                    aspect_ratio: optional_string(map, "aspectRatio")?,
                    quality: optional_string(map, "quality")?,
                })
                .await
        }
        "close" => {
            backend
                .close_project(ProjectSelector {
                    name: optional_string(map, "name")?,
                    id: optional_string(map, "id")?,
                    path: optional_string(map, "path")?,
                })
                .await
        }
        other => Err(BackendError::message(format!(
            "unsupported action '{other}'"
        ))),
    }
}
