use std::path::PathBuf;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::catalog::{ModelKind, ProviderKind};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum JobState {
    Preparing,
    Running,
    Downloading,
    Ready,
    Failed,
    Cancelled,
}

impl JobState {
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Ready | Self::Failed | Self::Cancelled)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerationRequest {
    pub model_id: String,
    pub prompt: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub aspect_ratio: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolution: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quality: Option<String>,
    #[serde(default)]
    pub reference_urls: Vec<String>,
    #[serde(default)]
    pub reference_paths: Vec<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub num_outputs: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stage_dir: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderHandle {
    pub provider: ProviderKind,
    pub endpoint: String,
    pub request_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cancel_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerationJob {
    pub id: String,
    pub state: JobState,
    pub model_id: String,
    pub kind: ModelKind,
    pub provider: ProviderKind,
    pub request: GenerationRequest,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_handle: Option<ProviderHandle>,
    #[serde(default)]
    pub result_urls: Vec<String>,
    #[serde(default)]
    pub staged_paths: Vec<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl GenerationJob {
    pub fn new(
        model_id: String,
        kind: ModelKind,
        provider: ProviderKind,
        request: GenerationRequest,
    ) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            state: JobState::Preparing,
            model_id,
            kind,
            provider,
            request,
            provider_handle: None,
            result_urls: Vec::new(),
            staged_paths: Vec::new(),
            error: None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct JobRuntime {
    pub cancel: CancellationToken,
}

#[derive(Debug, Clone, Copy)]
pub struct PollConfig {
    pub initial_delay: Duration,
    pub max_delay: Duration,
    pub max_attempts: u32,
}

impl Default for PollConfig {
    fn default() -> Self {
        Self {
            initial_delay: Duration::from_millis(250),
            max_delay: Duration::from_secs(5),
            max_attempts: 240,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum ProviderPoll {
    Pending,
    Succeeded { result_urls: Vec<String> },
    Failed { message: String },
    Cancelled,
}
