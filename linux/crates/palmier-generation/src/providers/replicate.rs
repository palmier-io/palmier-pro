use reqwest::Method;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::catalog::{CatalogModel, ProviderKind};
use crate::error::{GenerationError, Result};
use crate::http::{HttpClient, HttpRequest, bearer_headers};
use crate::job::{ProviderHandle, ProviderPoll};
use std::path::Path;

use crate::providers::{ProviderAdapter, extract_result_urls, reference_upload_stub};

const API_BASE: &str = "https://api.replicate.com/v1";

#[derive(Debug, Default, Clone)]
pub struct ReplicateAdapter {
    pub api_base: String,
}

impl ReplicateAdapter {
    pub fn new() -> Self {
        Self {
            api_base: API_BASE.to_owned(),
        }
    }

    pub fn with_base(api_base: impl Into<String>) -> Self {
        Self {
            api_base: api_base.into(),
        }
    }
}

#[derive(Debug, Deserialize)]
struct Prediction {
    id: String,
    status: String,
    #[serde(default)]
    output: Option<Value>,
    #[serde(default)]
    error: Option<Value>,
    #[serde(default)]
    urls: Option<PredictionUrls>,
}

#[derive(Debug, Deserialize)]
struct PredictionUrls {
    #[serde(default)]
    get: Option<String>,
    #[serde(default)]
    cancel: Option<String>,
}

impl ProviderAdapter for ReplicateAdapter {
    fn provider(&self) -> ProviderKind {
        ProviderKind::Replicate
    }

    async fn submit(
        &self,
        http: &dyn HttpClient,
        credential: &str,
        model: &CatalogModel,
        input: &Value,
    ) -> Result<ProviderHandle> {
        let url = format!(
            "{}/models/{}/predictions",
            self.api_base.trim_end_matches('/'),
            model.endpoint
        );
        let body = json!({ "input": input });
        let mut headers = bearer_headers(credential);
        headers.insert("content-type".to_owned(), "application/json".to_owned());
        let response = http
            .send(HttpRequest {
                method: Method::POST,
                url,
                headers,
                body: Some(
                    serde_json::to_vec(&body)
                        .map_err(|error| GenerationError::InvalidRequest(error.to_string()))?
                        .into(),
                ),
            })
            .await?;
        if !response.status.is_success() {
            return Err(GenerationError::ProviderStatus {
                status: response.status.as_u16(),
                body: response.text()?,
            });
        }
        let prediction: Prediction = response.json()?;
        Ok(ProviderHandle {
            provider: ProviderKind::Replicate,
            endpoint: model.endpoint.clone(),
            request_id: prediction.id,
            status_url: prediction.urls.as_ref().and_then(|urls| urls.get.clone()),
            result_url: prediction.urls.as_ref().and_then(|urls| urls.get.clone()),
            cancel_url: prediction
                .urls
                .as_ref()
                .and_then(|urls| urls.cancel.clone()),
        })
    }

    async fn poll(
        &self,
        http: &dyn HttpClient,
        credential: &str,
        model: &CatalogModel,
        handle: &ProviderHandle,
    ) -> Result<ProviderPoll> {
        let status_url = handle.status_url.clone().unwrap_or_else(|| {
            format!(
                "{}/predictions/{}",
                self.api_base.trim_end_matches('/'),
                handle.request_id
            )
        });
        let response = http
            .send(HttpRequest {
                method: Method::GET,
                url: status_url,
                headers: bearer_headers(credential),
                body: None,
            })
            .await?;
        if !response.status.is_success() {
            return Err(GenerationError::ProviderStatus {
                status: response.status.as_u16(),
                body: response.text()?,
            });
        }
        let prediction: Prediction = response.json()?;
        match prediction.status.as_str() {
            "starting" | "processing" => Ok(ProviderPoll::Pending),
            "succeeded" => {
                let output = prediction.output.ok_or_else(|| {
                    GenerationError::ProviderResponse("replicate succeeded without output".into())
                })?;
                let urls = extract_result_urls(model, &output)
                    .or_else(|_| extract_result_urls(model, &json!({ "output": output })))?;
                Ok(ProviderPoll::Succeeded { result_urls: urls })
            }
            "failed" => Ok(ProviderPoll::Failed {
                message: prediction
                    .error
                    .map(|value| value.to_string())
                    .unwrap_or_else(|| "replicate generation failed".into()),
            }),
            "canceled" | "cancelled" => Ok(ProviderPoll::Cancelled),
            other => Err(GenerationError::ProviderResponse(format!(
                "unknown replicate status {other}"
            ))),
        }
    }

    async fn cancel(
        &self,
        http: &dyn HttpClient,
        credential: &str,
        handle: &ProviderHandle,
    ) -> Result<()> {
        let cancel_url = handle.cancel_url.clone().unwrap_or_else(|| {
            format!(
                "{}/predictions/{}/cancel",
                self.api_base.trim_end_matches('/'),
                handle.request_id
            )
        });
        let response = http
            .send(HttpRequest {
                method: Method::POST,
                url: cancel_url,
                headers: bearer_headers(credential),
                body: None,
            })
            .await?;
        if response.status.is_success() || response.status.as_u16() == 404 {
            Ok(())
        } else {
            Err(GenerationError::ProviderStatus {
                status: response.status.as_u16(),
                body: response.text()?,
            })
        }
    }

    async fn upload_reference(
        &self,
        _http: &dyn HttpClient,
        _credential: &str,
        path: &Path,
    ) -> Result<String> {
        reference_upload_stub(ProviderKind::Replicate, path)
    }
}
