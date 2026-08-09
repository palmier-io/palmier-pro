use std::path::PathBuf;

use palmier_core::{EditorSnapshot, MutationReceipt};
use palmier_project::ProjectEntry;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenProjectSummary {
    pub project_id: Uuid,
    pub path: Option<PathBuf>,
    pub dirty: bool,
    pub revision: u64,
    pub undo_depth: usize,
    pub redo_depth: usize,
    pub active_timeline_id: Option<String>,
    pub timeline_count: usize,
    pub media_entry_count: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectView {
    pub summary: OpenProjectSummary,
    pub snapshot: EditorSnapshot,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditResult {
    pub project_id: Uuid,
    pub receipt: MutationReceipt,
    pub revision: u64,
    pub dirty: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snapshot: Option<EditorSnapshot>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreviewResult {
    pub project_id: Uuid,
    pub expected_revision: u64,
    pub receipt: MutationReceipt,
    pub snapshot: EditorSnapshot,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportedMediaEntry {
    pub asset_id: String,
    pub name: String,
    pub media_type: palmier_core::ClipType,
    pub source_path: PathBuf,
    pub duration: f64,
    pub installed: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportResult {
    pub project_id: Uuid,
    pub revision: u64,
    pub dirty: bool,
    pub entries: Vec<ImportedMediaEntry>,
    pub rejected_unsupported_names: Vec<String>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BootstrapPayload {
    pub recent_projects: Vec<ProjectEntry>,
    pub open_projects: Vec<OpenProjectSummary>,
}

#[cfg(feature = "media")]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportJobSummary {
    pub job_id: Uuid,
    pub project_id: Uuid,
    pub state: palmier_media::ExportState,
}
