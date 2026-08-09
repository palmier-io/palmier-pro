use reqwest::Method;
use serde::Deserialize;
use serde_json::Value;

use crate::catalog::{CatalogModel, ProviderKind};
use crate::error::{GenerationError, Result};
use crate::http::{HttpClient, HttpRequest, fal_headers};
use crate::job::{ProviderHandle, ProviderPoll};
use std::path::Path;

use crate::providers::{ProviderAdapter, extract_result_urls, reference_upload_stub};

const QUEUE_BASE: &str = "https://queue.fal.run";

#[derive(Debug, Default, Clone)]
pub struct FalAdapter {
    pub queue_base: String,
}

impl FalAdapter {
    pub fn new() -> Self {
        Self {
            queue_base: QUEUE_BASE.to_owned(),
        }
    }

    pub fn with_base(queue_base: impl Into<String>) -> Self {
        Self {
            queue_base: queue_base.into(),
        }
    }
}

#[derive(Debug, Deserialize)]
struct SubmitResponse {
    request_id: String,
    #[serde(default)]
    status_url: Option<String>,
    #[serde(default)]
    response_url: Option<String>,
    #[serde(default)]
    cancel_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct StatusResponse {
    status: String,
    #[serde(default)]
    response_url: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

impl ProviderAdapter for FalAdapter {
    fn provider(&self) -> ProviderKind {
        ProviderKind::Fal
    }

    async fn submit(
        &self,
        http: &dyn HttpClient,
        credential: &str,
        model: &CatalogModel,
        input: &Value,
    ) -> Result<ProviderHandle> {
        let url = format!(
            "{}/{}",
            self.queue_base.trim_end_matches('/'),
            model.endpoint
        );
        let mut request = HttpRequest {
            method: Method::POST,
            url,
            headers: fal_headers(credential),
            body: Some(
                serde_json::to_vec(input)
                    .map_err(|error| GenerationError::InvalidRequest(error.to_string()))?
                    .into(),
            ),
        };
        request
            .headers
            .insert("content-type".to_owned(), "application/json".to_owned());
        let response = http.send(request).await?;
        if !response.status.is_success() {
            return Err(GenerationError::ProviderStatus {
                status: response.status.as_u16(),
                body: response.text()?,
            });
        }
        let body: SubmitResponse = response.json()?;
        Ok(ProviderHandle {
            provider: ProviderKind::Fal,
            endpoint: model.endpoint.clone(),
            request_id: body.request_id,
            status_url: body.status_url,
            result_url: body.response_url,
            cancel_url: body.cancel_url,
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
                "{}/{}/requests/{}/status",
                self.queue_base.trim_end_matches('/'),
                handle.endpoint,
                handle.request_id
            )
        });
        let response = http
            .send(HttpRequest {
                method: Method::GET,
                url: status_url,
                headers: fal_headers(credential),
                body: None,
            })
            .await?;
        if !response.status.is_success() {
            return Err(GenerationError::ProviderStatus {
                status: response.status.as_u16(),
                body: response.text()?,
            });
        }
        let status: StatusResponse = response.json()?;
        match status.status.as_str() {
            "IN_QUEUE" | "IN_PROGRESS" => Ok(ProviderPoll::Pending),
            "COMPLETED" => {
                let result_url = status
                    .response_url
                    .or_else(|| handle.result_url.clone())
                    .unwrap_or_else(|| {
                        format!(
                            "{}/{}/requests/{}",
                            self.queue_base.trim_end_matches('/'),
                            handle.endpoint,
                            handle.request_id
                        )
                    });
                let result = http
                    .send(HttpRequest {
                        method: Method::GET,
                        url: result_url,
                        headers: fal_headers(credential),
                        body: None,
                    })
                    .await?;
                if result.status.as_u16() == 202 {
                    return Ok(ProviderPoll::Pending);
                }
                if !result.status.is_success() {
                    return Err(GenerationError::ProviderStatus {
                        status: result.status.as_u16(),
                        body: result.text()?,
                    });
                }
                let payload: Value = result.json()?;
                let urls = extract_result_urls(model, &payload)?;
                Ok(ProviderPoll::Succeeded { result_urls: urls })
            }
            "FAILED" => Ok(ProviderPoll::Failed {
                message: status
                    .error
                    .unwrap_or_else(|| "fal generation failed".into()),
            }),
            "CANCELED" | "CANCELLED" => Ok(ProviderPoll::Cancelled),
            other => Err(GenerationError::ProviderResponse(format!(
                "unknown fal status {other}"
            ))),
        }
    }

    async fn cancel(
        &self,
        http: &dyn HttpClient,
        credential: &str,
        handle: &ProviderHandle,
    ) -> Result<()> {
        let Some(cancel_url) = &handle.cancel_url else {
            return Ok(());
        };
        let response = http
            .send(HttpRequest {
                method: Method::PUT,
                url: cancel_url.clone(),
                headers: fal_headers(credential),
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
        reference_upload_stub(ProviderKind::Fal, path)
    }
}
