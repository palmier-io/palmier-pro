mod fal;
mod replicate;

use std::path::Path;

use serde_json::{Map, Value};

use crate::catalog::{CatalogModel, ModelKind, ProviderKind};
use crate::error::{GenerationError, Result};
use crate::http::HttpClient;
use crate::job::{GenerationRequest, ProviderHandle, ProviderPoll};

pub use fal::FalAdapter;
pub use replicate::ReplicateAdapter;

pub trait ProviderAdapter: Send + Sync {
    fn provider(&self) -> ProviderKind;

    fn submit(
        &self,
        http: &dyn HttpClient,
        credential: &str,
        model: &CatalogModel,
        input: &Value,
    ) -> impl std::future::Future<Output = Result<ProviderHandle>> + Send;

    fn poll(
        &self,
        http: &dyn HttpClient,
        credential: &str,
        model: &CatalogModel,
        handle: &ProviderHandle,
    ) -> impl std::future::Future<Output = Result<ProviderPoll>> + Send;

    fn cancel(
        &self,
        http: &dyn HttpClient,
        credential: &str,
        handle: &ProviderHandle,
    ) -> impl std::future::Future<Output = Result<()>> + Send;

    fn upload_reference(
        &self,
        http: &dyn HttpClient,
        credential: &str,
        path: &Path,
    ) -> impl std::future::Future<Output = Result<String>> + Send;
}

pub(crate) fn reference_upload_stub(provider: ProviderKind, path: &Path) -> Result<String> {
    Err(GenerationError::ReferenceUploadStub(format!(
        "{} ({})",
        provider.as_str(),
        path.display()
    )))
}

pub fn build_provider_input(model: &CatalogModel, request: &GenerationRequest) -> Result<Value> {
    validate_request(model, request)?;
    let mut map = Map::new();
    if !request.prompt.is_empty() {
        map.insert("prompt".into(), Value::String(request.prompt.clone()));
    }
    match model.provider {
        ProviderKind::Fal => insert_fal_fields(&mut map, model, request),
        ProviderKind::Replicate => insert_replicate_fields(&mut map, model, request),
    }
    Ok(Value::Object(map))
}

fn validate_request(model: &CatalogModel, request: &GenerationRequest) -> Result<()> {
    if model.kind != ModelKind::Upscale && request.prompt.trim().is_empty() {
        return Err(GenerationError::InvalidRequest("prompt is required".into()));
    }
    if let Some(aspect) = &request.aspect_ratio
        && !model.aspect_ratios.is_empty()
        && !model.aspect_ratios.iter().any(|value| value == aspect)
    {
        return Err(GenerationError::InvalidRequest(format!(
            "aspect ratio {aspect} is not supported by {}",
            model.id
        )));
    }
    if let Some(duration) = request.duration
        && !model.durations.is_empty()
        && !model.durations.contains(&duration)
    {
        return Err(GenerationError::InvalidRequest(format!(
            "duration {duration} is not supported by {}",
            model.id
        )));
    }
    let refs = request.reference_urls.len() + request.reference_paths.len();
    if refs as u32 > model.max_references {
        return Err(GenerationError::InvalidRequest(format!(
            "{} accepts at most {} reference(s)",
            model.id, model.max_references
        )));
    }
    if model.requires_source
        && request.source_url.is_none()
        && request.reference_urls.is_empty()
        && request.reference_paths.is_empty()
    {
        return Err(GenerationError::InvalidRequest(format!(
            "{} requires a source media URL or reference",
            model.id
        )));
    }
    Ok(())
}

fn insert_fal_fields(
    map: &mut Map<String, Value>,
    model: &CatalogModel,
    request: &GenerationRequest,
) {
    if let Some(aspect) = &request.aspect_ratio {
        match model.kind {
            ModelKind::Image => {
                map.insert("image_size".into(), Value::String(aspect.clone()));
            }
            ModelKind::Video | ModelKind::Audio | ModelKind::Upscale => {
                map.insert("aspect_ratio".into(), Value::String(aspect.clone()));
            }
        }
    }
    if let Some(duration) = request.duration {
        map.insert("duration".into(), Value::Number(duration.into()));
    }
    if let Some(source) = &request.source_url {
        let key = match model.kind {
            ModelKind::Upscale | ModelKind::Image => "image_url",
            ModelKind::Video => "video_url",
            ModelKind::Audio => "audio_url",
        };
        map.insert(key.into(), Value::String(source.clone()));
    }
    if !request.reference_urls.is_empty() {
        let key = match model.kind {
            ModelKind::Image | ModelKind::Upscale => "image_url",
            ModelKind::Video => "image_url",
            ModelKind::Audio => "audio_url",
        };
        if request.reference_urls.len() == 1 {
            map.insert(key.into(), Value::String(request.reference_urls[0].clone()));
        } else {
            map.insert(
                "image_urls".into(),
                Value::Array(
                    request
                        .reference_urls
                        .iter()
                        .cloned()
                        .map(Value::String)
                        .collect(),
                ),
            );
        }
    }
}

fn insert_replicate_fields(
    map: &mut Map<String, Value>,
    model: &CatalogModel,
    request: &GenerationRequest,
) {
    if let Some(aspect) = &request.aspect_ratio {
        map.insert("aspect_ratio".into(), Value::String(aspect.clone()));
    }
    if let Some(duration) = request.duration {
        map.insert("duration".into(), Value::Number(duration.into()));
    }
    if let Some(source) = &request.source_url {
        map.insert("image".into(), Value::String(source.clone()));
    }
    if let Some(url) = request.reference_urls.first() {
        let key = match model.kind {
            ModelKind::Image | ModelKind::Upscale => "image",
            ModelKind::Video => "image",
            ModelKind::Audio => "input_audio",
        };
        map.insert(key.into(), Value::String(url.clone()));
    }
    if let Some(num) = request.num_outputs {
        map.insert("num_outputs".into(), Value::Number(num.into()));
    }
}

pub fn extract_result_urls(model: &CatalogModel, payload: &Value) -> Result<Vec<String>> {
    if let Some(urls) = extract_by_path(payload, &model.result_path)? {
        return Ok(vec![urls]);
    }
    if let Some(array) = payload.as_array() {
        let urls = array
            .iter()
            .filter_map(|value| value.as_str().map(str::to_owned))
            .collect::<Vec<_>>();
        if !urls.is_empty() {
            return Ok(urls);
        }
    }
    if let Some(images) = payload.get("images").and_then(Value::as_array) {
        let urls = images
            .iter()
            .filter_map(|image| image.get("url").and_then(Value::as_str).map(str::to_owned))
            .collect::<Vec<_>>();
        if !urls.is_empty() {
            return Ok(urls);
        }
    }
    if let Some(url) = payload
        .pointer("/video/url")
        .and_then(Value::as_str)
        .or_else(|| payload.pointer("/image/url").and_then(Value::as_str))
        .or_else(|| payload.pointer("/audio_file/url").and_then(Value::as_str))
        .or_else(|| payload.get("output").and_then(Value::as_str))
    {
        return Ok(vec![url.to_owned()]);
    }
    if let Some(output) = payload.get("output") {
        if let Some(url) = output.as_str() {
            return Ok(vec![url.to_owned()]);
        }
        if let Some(array) = output.as_array() {
            let urls = array
                .iter()
                .filter_map(|value| value.as_str().map(str::to_owned))
                .collect::<Vec<_>>();
            if !urls.is_empty() {
                return Ok(urls);
            }
        }
    }
    Err(GenerationError::ProviderResponse(
        "could not locate result URL in provider payload".into(),
    ))
}

fn extract_by_path(value: &Value, path: &[Value]) -> Result<Option<String>> {
    let mut current = value;
    for segment in path {
        current = if let Some(key) = segment.as_str() {
            match current.get(key) {
                Some(next) => next,
                None => return Ok(None),
            }
        } else if let Some(index) = segment.as_u64() {
            match current
                .as_array()
                .and_then(|array| array.get(index as usize))
            {
                Some(next) => next,
                None => return Ok(None),
            }
        } else {
            return Err(GenerationError::Catalog(
                "resultPath segments must be strings or integers".into(),
            ));
        };
    }
    Ok(current.as_str().map(str::to_owned))
}
