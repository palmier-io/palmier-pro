use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use axum::Router;
use axum::body::Body;
use axum::extract::State;
use axum::http::{Request, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::any;
use palmier_generation::{
    DownloadPolicy, FalAdapter, GenerationError, GenerationRequest, GenerationService, JobState,
    MemoryCredentialStore, PollConfig, ProviderKind, ReplicateAdapter, ReqwestHttpClient,
    generate_image, list_models,
};
use serde_json::json;
use tempfile::tempdir;
use tokio::sync::Mutex;

#[derive(Clone)]
struct MockState {
    base: String,
    polls: Arc<AtomicUsize>,
    cancelled: Arc<Mutex<bool>>,
    fail: bool,
}

async fn handle(State(state): State<MockState>, req: Request<Body>) -> Response {
    let path = req.uri().path().to_owned();
    let method = req.method().clone();

    if path == "/asset.png" {
        return (
            [(axum::http::header::CONTENT_TYPE, "image/png")],
            b"PNGDATA".as_slice(),
        )
            .into_response();
    }

    if method == axum::http::Method::POST && !path.contains("/requests/") {
        let base = state.base.trim_end_matches('/');
        return axum::Json(json!({
            "request_id": "req-1",
            "status_url": format!("{base}/fal-ai/flux/schnell/requests/req-1/status"),
            "response_url": format!("{base}/fal-ai/flux/schnell/requests/req-1"),
            "cancel_url": format!("{base}/fal-ai/flux/schnell/requests/req-1/cancel")
        }))
        .into_response();
    }

    if path.ends_with("/cancel") {
        *state.cancelled.lock().await = true;
        return StatusCode::OK.into_response();
    }

    if path.ends_with("/status") {
        if *state.cancelled.lock().await {
            return axum::Json(json!({ "status": "CANCELED" })).into_response();
        }
        if state.fail {
            return axum::Json(json!({ "status": "FAILED", "error": "boom" })).into_response();
        }
        let count = state.polls.fetch_add(1, Ordering::SeqCst);
        if count < 1 {
            return axum::Json(json!({ "status": "IN_PROGRESS" })).into_response();
        }
        let base = state.base.trim_end_matches('/');
        return axum::Json(json!({
            "status": "COMPLETED",
            "response_url": format!("{base}/fal-ai/flux/schnell/requests/req-1")
        }))
        .into_response();
    }

    if path.contains("/requests/") {
        let base = state.base.trim_end_matches('/');
        return axum::Json(json!({
            "images": [{ "url": format!("{base}/asset.png") }]
        }))
        .into_response();
    }

    StatusCode::NOT_FOUND.into_response()
}

async fn spawn_fal_mock(fail: bool) -> SocketAddr {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let addr = listener.local_addr().expect("addr");
    let state = MockState {
        base: format!("http://{addr}"),
        polls: Arc::new(AtomicUsize::new(0)),
        cancelled: Arc::new(Mutex::new(false)),
        fail,
    };
    let app = Router::new().fallback(any(handle)).with_state(state);
    tokio::spawn(async move {
        axum::serve(listener, app).await.expect("serve");
    });
    addr
}

async fn build_service(addr: SocketAddr, credentials: MemoryCredentialStore) -> GenerationService {
    let base = format!("http://{addr}");
    let stage = tempdir().expect("stage").keep();
    GenerationService::with_adapters(
        Arc::new(credentials),
        Arc::new(ReqwestHttpClient::new().expect("client")),
        stage,
        FalAdapter::with_base(base.clone()),
        ReplicateAdapter::with_base(format!("{base}/v1")),
        PollConfig {
            initial_delay: Duration::from_millis(20),
            max_delay: Duration::from_millis(40),
            max_attempts: 50,
        },
        DownloadPolicy {
            max_bytes: 1024 * 1024,
            allow_loopback: true,
        },
    )
    .expect("service")
}

#[tokio::test]
async fn catalog_lists_expected_kinds() {
    let service = build_service(spawn_fal_mock(false).await, MemoryCredentialStore::new()).await;
    let models = list_models(&service).await.expect("models");
    assert!(models.iter().any(|model| model.id == "flux-schnell"));
    assert!(
        models
            .iter()
            .any(|model| model.kind == palmier_generation::ModelKind::Video)
    );
    assert!(
        models
            .iter()
            .any(|model| model.kind == palmier_generation::ModelKind::Audio)
    );
    assert!(
        models
            .iter()
            .any(|model| model.kind == palmier_generation::ModelKind::Upscale)
    );
}

#[tokio::test]
async fn can_generate_requires_provider_key() {
    let service = build_service(spawn_fal_mock(false).await, MemoryCredentialStore::new()).await;
    assert!(!service.can_generate("flux-schnell").await.expect("check"));
    service
        .credentials()
        .set_secret(ProviderKind::Fal.credential_key(), "test-key")
        .expect("set");
    assert!(service.can_generate("flux-schnell").await.expect("check"));
    assert!(
        !service
            .can_generate("sdxl")
            .await
            .expect("replicate missing")
    );
}

#[tokio::test]
async fn missing_credential_fails_start() {
    let service = build_service(spawn_fal_mock(false).await, MemoryCredentialStore::new()).await;
    let error = service
        .start(GenerationRequest {
            model_id: "flux-schnell".into(),
            prompt: "sunset".into(),
            aspect_ratio: Some("1:1".into()),
            duration: None,
            resolution: None,
            quality: None,
            reference_urls: Vec::new(),
            reference_paths: Vec::new(),
            source_url: None,
            num_outputs: None,
            stage_dir: None,
        })
        .await
        .expect_err("missing cred");
    assert!(matches!(error, GenerationError::CredentialMissing { .. }));
}

#[tokio::test]
async fn mock_successful_image_job() {
    let service = build_service(
        spawn_fal_mock(false).await,
        MemoryCredentialStore::with_provider(ProviderKind::Fal, "test-key"),
    )
    .await;
    let job = generate_image(
        &service,
        palmier_generation::GenerateImageParams {
            model_id: "flux-schnell".into(),
            prompt: "a tree".into(),
            aspect_ratio: Some("1:1".into()),
            reference_urls: Vec::new(),
            num_outputs: None,
            stage_dir: None,
        },
    )
    .await
    .expect("start");

    let ready = service
        .wait_until(
            &job.id,
            |job| job.state == JobState::Ready || job.state.is_terminal(),
            Duration::from_secs(5),
        )
        .await
        .expect("wait");
    assert_eq!(ready.state, JobState::Ready, "error={:?}", ready.error);
    assert_eq!(ready.staged_paths.len(), 1);
    let bytes = tokio::fs::read(&ready.staged_paths[0])
        .await
        .expect("read staged");
    assert_eq!(bytes, b"PNGDATA");
}

#[tokio::test]
async fn cancel_marks_job_cancelled() {
    let service = build_service(
        spawn_fal_mock(false).await,
        MemoryCredentialStore::with_provider(ProviderKind::Fal, "test-key"),
    )
    .await;
    let job = service
        .start(GenerationRequest {
            model_id: "flux-schnell".into(),
            prompt: "slow".into(),
            aspect_ratio: Some("1:1".into()),
            duration: None,
            resolution: None,
            quality: None,
            reference_urls: Vec::new(),
            reference_paths: Vec::new(),
            source_url: None,
            num_outputs: None,
            stage_dir: None,
        })
        .await
        .expect("start");
    let cancelled = service.cancel(&job.id).await.expect("cancel");
    assert_eq!(cancelled.state, JobState::Cancelled);
}

#[tokio::test]
async fn provider_failure_marks_failed() {
    let service = build_service(
        spawn_fal_mock(true).await,
        MemoryCredentialStore::with_provider(ProviderKind::Fal, "test-key"),
    )
    .await;
    let job = service
        .start(GenerationRequest {
            model_id: "flux-schnell".into(),
            prompt: "fail".into(),
            aspect_ratio: Some("1:1".into()),
            duration: None,
            resolution: None,
            quality: None,
            reference_urls: Vec::new(),
            reference_paths: Vec::new(),
            source_url: None,
            num_outputs: None,
            stage_dir: None,
        })
        .await
        .expect("start");
    let failed = service
        .wait_until(
            &job.id,
            |job| job.state == JobState::Failed || job.state.is_terminal(),
            Duration::from_secs(5),
        )
        .await
        .expect("wait");
    assert_eq!(failed.state, JobState::Failed);
    assert!(failed.error.as_deref().unwrap_or("").contains("boom"));
}

#[test]
fn catalog_json_is_valid() {
    let catalog = palmier_generation::ModelCatalog::bundled().expect("catalog");
    assert_eq!(catalog.version(), palmier_generation::CATALOG_VERSION);
    assert!(catalog.get("kling-video").is_some());
    assert!(catalog.get("real-esrgan").is_some());
}
