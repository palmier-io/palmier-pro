use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderSettings {
    pub fal_key: String,
    pub replicate_key: String,
    pub fal_configured: bool,
    pub replicate_configured: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unavailable_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecentProject {
    pub id: String,
    pub name: String,
    pub path: String,
    pub updated_at: String,
    pub duration_label: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UiBootstrapPayload {
    pub recent_projects: Vec<RecentProject>,
    pub settings: ProviderSettings,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaStatus {
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

impl MediaStatus {
    pub fn ready() -> Self {
        Self {
            kind: "ready".into(),
            progress: None,
            label: None,
            reason: None,
            message: None,
        }
    }

    pub fn generating(progress: f64, label: impl Into<String>) -> Self {
        Self {
            kind: "generating".into(),
            progress: Some(progress),
            label: Some(label.into()),
            reason: None,
            message: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaAsset {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub duration_frames: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_path: Option<String>,
    pub created_at: String,
    pub status: MediaStatus,
    pub accent: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generated: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipTransform {
    pub position_x: f64,
    pub position_y: f64,
    pub scale: f64,
    pub rotation: f64,
    pub opacity: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelineClip {
    pub id: String,
    pub asset_id: String,
    pub name: String,
    pub kind: String,
    pub track_id: String,
    pub start_frame: i64,
    pub duration_frames: i64,
    pub source_offset_frames: i64,
    pub trim_end_frames: i64,
    pub speed: f64,
    pub volume: f64,
    pub fade_in_frames: i64,
    pub fade_out_frames: i64,
    pub transform: ClipTransform,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelineTrack {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub muted: bool,
    pub hidden: bool,
    pub locked: bool,
    pub clips: Vec<TimelineClip>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectDocument {
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    pub width: i32,
    pub height: i32,
    pub fps: i32,
    pub updated_at: String,
    pub media: Vec<MediaAsset>,
    pub tracks: Vec<TimelineTrack>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportCandidate {
    pub name: String,
    #[serde(rename = "type")]
    pub media_type: String,
    pub size: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UiGenerationRequest {
    pub project_id: String,
    pub kind: String,
    pub model: String,
    pub prompt: String,
    pub aspect_ratio: String,
    pub duration_seconds: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UiGenerationJob {
    pub id: String,
    pub asset_id: String,
    pub label: String,
    pub progress: f64,
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StartGenerationResult {
    pub job: UiGenerationJob,
    pub asset: MediaAsset,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UiExportRequest {
    pub project_id: String,
    pub destination: String,
    pub codec: String,
    pub resolution: String,
    pub timeline_format: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UiExportJob {
    pub id: String,
    pub filename: String,
    pub progress: f64,
    pub status: String,
    pub created_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DecodePreviewFrameResult {
    pub width: u32,
    pub height: u32,
    pub mime_type: String,
    pub data_base64: String,
}
