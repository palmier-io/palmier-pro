use std::path::PathBuf;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::catalog::{CatalogModel, ModelCatalog, ModelKind, ProviderKind};
use crate::error::Result;
use crate::job::{GenerationJob, GenerationRequest};
use crate::service::GenerationService;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelSummary {
    pub id: String,
    pub kind: ModelKind,
    pub display_name: String,
    pub provider: ProviderKind,
    pub can_generate: bool,
    pub aspect_ratios: Vec<String>,
    pub durations: Vec<i32>,
    pub file_extension: String,
}

impl From<&CatalogModel> for ModelSummary {
    fn from(model: &CatalogModel) -> Self {
        Self {
            id: model.id.clone(),
            kind: model.kind,
            display_name: model.display_name.clone(),
            provider: model.provider,
            can_generate: false,
            aspect_ratios: model.aspect_ratios.clone(),
            durations: model.durations.clone(),
            file_extension: model.file_extension.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerateVideoParams {
    pub model_id: String,
    pub prompt: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub aspect_ratio: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration: Option<i32>,
    #[serde(default)]
    pub reference_urls: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stage_dir: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerateImageParams {
    pub model_id: String,
    pub prompt: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub aspect_ratio: Option<String>,
    #[serde(default)]
    pub reference_urls: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub num_outputs: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stage_dir: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerateAudioParams {
    pub model_id: String,
    pub prompt: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stage_dir: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpscaleMediaParams {
    pub model_id: String,
    pub source_url: String,
    #[serde(default)]
    pub prompt: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stage_dir: Option<PathBuf>,
}

pub async fn list_models(service: &GenerationService) -> Result<Vec<ModelSummary>> {
    list_models_filtered(service, None).await
}

pub async fn list_models_filtered(
    service: &GenerationService,
    kind: Option<ModelKind>,
) -> Result<Vec<ModelSummary>> {
    let mut models = Vec::new();
    for model in service.catalog().models() {
        if let Some(wanted) = kind
            && model.kind != wanted
        {
            continue;
        }
        let mut summary = ModelSummary::from(model);
        summary.can_generate = service.can_generate(&model.id).await?;
        models.push(summary);
    }
    Ok(models)
}

pub async fn generate_video(
    service: &GenerationService,
    params: GenerateVideoParams,
) -> Result<GenerationJob> {
    ensure_kind(service.catalog(), &params.model_id, ModelKind::Video)?;
    service
        .start(GenerationRequest {
            model_id: params.model_id,
            prompt: params.prompt,
            aspect_ratio: params.aspect_ratio,
            duration: params.duration,
            resolution: None,
            quality: None,
            reference_urls: params.reference_urls,
            reference_paths: Vec::new(),
            source_url: None,
            num_outputs: None,
            stage_dir: params.stage_dir,
        })
        .await
}

pub async fn generate_image(
    service: &GenerationService,
    params: GenerateImageParams,
) -> Result<GenerationJob> {
    ensure_kind(service.catalog(), &params.model_id, ModelKind::Image)?;
    service
        .start(GenerationRequest {
            model_id: params.model_id,
            prompt: params.prompt,
            aspect_ratio: params.aspect_ratio,
            duration: None,
            resolution: None,
            quality: None,
            reference_urls: params.reference_urls,
            reference_paths: Vec::new(),
            source_url: None,
            num_outputs: params.num_outputs,
            stage_dir: params.stage_dir,
        })
        .await
}

pub async fn generate_audio(
    service: &GenerationService,
    params: GenerateAudioParams,
) -> Result<GenerationJob> {
    ensure_kind(service.catalog(), &params.model_id, ModelKind::Audio)?;
    service
        .start(GenerationRequest {
            model_id: params.model_id,
            prompt: params.prompt,
            aspect_ratio: None,
            duration: params.duration,
            resolution: None,
            quality: None,
            reference_urls: Vec::new(),
            reference_paths: Vec::new(),
            source_url: None,
            num_outputs: None,
            stage_dir: params.stage_dir,
        })
        .await
}

pub async fn upscale_media(
    service: &GenerationService,
    params: UpscaleMediaParams,
) -> Result<GenerationJob> {
    ensure_kind(service.catalog(), &params.model_id, ModelKind::Upscale)?;
    service
        .start(GenerationRequest {
            model_id: params.model_id,
            prompt: params.prompt,
            aspect_ratio: None,
            duration: None,
            resolution: None,
            quality: None,
            reference_urls: Vec::new(),
            reference_paths: Vec::new(),
            source_url: Some(params.source_url),
            num_outputs: None,
            stage_dir: params.stage_dir,
        })
        .await
}

fn ensure_kind(catalog: &ModelCatalog, model_id: &str, kind: ModelKind) -> Result<()> {
    let model = catalog.require(model_id)?;
    if model.kind != kind {
        return Err(crate::error::GenerationError::InvalidRequest(format!(
            "model {model_id} is {:?}, expected {kind:?}",
            model.kind
        )));
    }
    Ok(())
}

pub type SharedGenerationService = Arc<GenerationService>;
