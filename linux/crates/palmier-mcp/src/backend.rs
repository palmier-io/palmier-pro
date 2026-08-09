use std::collections::HashSet;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use palmier_core::{EditorCommand, MutationReceipt};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::BackendResult;

pub type BoxFut<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// Domain seam for MCP tools. `palmier-service` can supply an `Arc<dyn McpEditorBackend>`.
pub trait McpEditorBackend: Send + Sync {
    fn list_projects(&self) -> BoxFut<'_, BackendResult<Value>>;
    fn open_project(&self, request: ProjectSelector) -> BoxFut<'_, BackendResult<Value>>;
    fn create_project(&self, request: CreateProjectRequest) -> BoxFut<'_, BackendResult<Value>>;
    fn close_project(&self, request: ProjectSelector) -> BoxFut<'_, BackendResult<Value>>;
    fn has_active_project(&self) -> BoxFut<'_, bool>;

    fn id_universe(&self) -> BoxFut<'_, BackendResult<HashSet<String>>>;

    fn get_timeline(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;
    fn create_timeline(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;
    fn set_active_timeline(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;
    fn set_project_settings(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;

    fn get_media(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;
    fn import_media(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;
    fn organize_media(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;
    fn capture_frame(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;

    fn execute(&self, command: EditorCommand) -> BoxFut<'_, BackendResult<MutationReceipt>>;
    fn add_clips(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;
    fn insert_clips(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;
    fn move_clips(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;
    fn remove_clips(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;
    fn split_clips(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;
    fn ripple_delete_ranges(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;
    fn manage_clip_links(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;
    fn manage_tracks(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;
    fn set_clip_properties(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;

    fn add_texts(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;
    fn update_text(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;

    fn apply_color(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;
    fn apply_effect(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;

    fn export_project(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;
    fn manage_exports(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;

    fn list_models(&self, _args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async {
            Err(crate::error::BackendError::message(
                "generation is unavailable in this backend",
            ))
        })
    }

    fn generate_video(&self, _args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async {
            Err(crate::error::BackendError::message(
                "generation is unavailable in this backend",
            ))
        })
    }

    fn generate_image(&self, _args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async {
            Err(crate::error::BackendError::message(
                "generation is unavailable in this backend",
            ))
        })
    }

    fn generate_audio(&self, _args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async {
            Err(crate::error::BackendError::message(
                "generation is unavailable in this backend",
            ))
        })
    }

    fn upscale_media(&self, _args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async {
            Err(crate::error::BackendError::message(
                "generation is unavailable in this backend",
            ))
        })
    }

    fn undo(&self, args: Value) -> BoxFut<'_, BackendResult<Value>>;
}

pub type SharedBackend = Arc<dyn McpEditorBackend>;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectSelector {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub path: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateProjectRequest {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub fps: Option<i32>,
    #[serde(default)]
    pub aspect_ratio: Option<String>,
    #[serde(default)]
    pub quality: Option<String>,
}
