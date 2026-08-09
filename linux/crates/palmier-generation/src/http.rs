use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use bytes::Bytes;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use reqwest::{Client, Method, StatusCode};

use crate::error::{GenerationError, Result};

#[derive(Debug, Clone)]
pub struct HttpRequest {
    pub method: Method,
    pub url: String,
    pub headers: HashMap<String, String>,
    pub body: Option<Bytes>,
}

#[derive(Debug, Clone)]
pub struct HttpResponse {
    pub status: StatusCode,
    pub headers: HeaderMap,
    pub body: Bytes,
}

impl HttpResponse {
    pub fn text(&self) -> Result<String> {
        String::from_utf8(self.body.to_vec())
            .map_err(|error| GenerationError::ProviderResponse(error.to_string()))
    }

    pub fn json<T: serde::de::DeserializeOwned>(&self) -> Result<T> {
        serde_json::from_slice(&self.body)
            .map_err(|error| GenerationError::ProviderResponse(error.to_string()))
    }
}

pub trait HttpClient: Send + Sync {
    fn send(
        &self,
        request: HttpRequest,
    ) -> Pin<Box<dyn Future<Output = Result<HttpResponse>> + Send + '_>>;
}

#[derive(Debug, Clone)]
pub struct ReqwestHttpClient {
    client: Client,
}

impl ReqwestHttpClient {
    pub fn new() -> Result<Self> {
        let client = Client::builder()
            .redirect(reqwest::redirect::Policy::limited(5))
            .build()
            .map_err(|error| GenerationError::Http(error.to_string()))?;
        Ok(Self { client })
    }
}

impl Default for ReqwestHttpClient {
    fn default() -> Self {
        Self::new().expect("reqwest client")
    }
}

impl HttpClient for ReqwestHttpClient {
    fn send(
        &self,
        request: HttpRequest,
    ) -> Pin<Box<dyn Future<Output = Result<HttpResponse>> + Send + '_>> {
        Box::pin(async move {
            let mut builder = self.client.request(request.method, &request.url);
            for (name, value) in &request.headers {
                let header_name = HeaderName::from_bytes(name.as_bytes())
                    .map_err(|error| GenerationError::Http(error.to_string()))?;
                let header_value = HeaderValue::from_str(value)
                    .map_err(|error| GenerationError::Http(error.to_string()))?;
                builder = builder.header(header_name, header_value);
            }
            if let Some(body) = request.body {
                builder = builder.body(body);
            }
            let response = builder
                .send()
                .await
                .map_err(|error| GenerationError::Http(error.to_string()))?;
            let status = response.status();
            let headers = response.headers().clone();
            let body = response
                .bytes()
                .await
                .map_err(|error| GenerationError::Http(error.to_string()))?;
            Ok(HttpResponse {
                status,
                headers,
                body,
            })
        })
    }
}

pub type SharedHttpClient = Arc<dyn HttpClient>;

pub fn bearer_headers(token: &str) -> HashMap<String, String> {
    let mut headers = HashMap::new();
    headers.insert("authorization".to_owned(), format!("Bearer {token}"));
    headers.insert("accept".to_owned(), "application/json".to_owned());
    headers
}

pub fn fal_headers(api_key: &str) -> HashMap<String, String> {
    let mut headers = HashMap::new();
    headers.insert("authorization".to_owned(), format!("Key {api_key}"));
    headers.insert("content-type".to_owned(), "application/json".to_owned());
    headers.insert("accept".to_owned(), "application/json".to_owned());
    headers
}
