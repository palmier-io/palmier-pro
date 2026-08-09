use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::Router;
use axum::body::Body;
use axum::extract::State;
use axum::http::{HeaderMap, HeaderName, HeaderValue, Method, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{any, get};
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio::sync::Mutex;
use tower_http::trace::TraceLayer;
use uuid::Uuid;

use crate::backend::SharedBackend;
use crate::protocol::{
    DEFAULT_PORT, JsonRpcRequest, JsonRpcResponse, PROTOCOL_HEADER, PROTOCOL_VERSION,
    SESSION_HEADER, initialize_result, is_initialize, is_notification,
};
use crate::tools::{call_tool, tools_list_payload};

const SESSION_IDLE_LIMIT: Duration = Duration::from_secs(3600);
const SESSION_COUNT_LIMIT: usize = 32;

#[derive(Clone)]
struct Session {
    last_used: Instant,
    tool_list_announced: bool,
}

#[derive(Clone)]
struct AppState {
    backend: SharedBackend,
    bind_port: u16,
    sessions: Arc<Mutex<HashMap<String, Session>>>,
}

pub struct McpServer {
    state: AppState,
}

pub struct McpServerHandle {
    pub addr: SocketAddr,
    shutdown: tokio_util::sync::CancellationToken,
    join: tokio::task::JoinHandle<()>,
}

impl McpServerHandle {
    pub async fn shutdown(self) {
        self.shutdown.cancel();
        let _ = self.join.await;
    }
}

impl McpServer {
    pub fn new(backend: SharedBackend) -> Self {
        Self::with_port(backend, DEFAULT_PORT)
    }

    pub fn with_port(backend: SharedBackend, bind_port: u16) -> Self {
        Self {
            state: AppState {
                backend,
                bind_port,
                sessions: Arc::new(Mutex::new(HashMap::new())),
            },
        }
    }

    pub fn router(&self) -> Router {
        Router::new()
            .route("/mcp", any(mcp_endpoint))
            .route("/", any(mcp_endpoint))
            .route("/.well-known/oauth-protected-resource", get(oauth_metadata))
            .layer(TraceLayer::new_for_http())
            .with_state(self.state.clone())
    }

    pub async fn serve(self, addr: SocketAddr) -> anyhow::Result<McpServerHandle> {
        let listener = TcpListener::bind(addr).await?;
        let bound = listener.local_addr()?;
        let shutdown = tokio_util::sync::CancellationToken::new();
        let cancel = shutdown.clone();
        let app = self.router();
        let join = tokio::spawn(async move {
            let server = axum::serve(listener, app).with_graceful_shutdown(async move {
                cancel.cancelled().await;
            });
            let _ = server.await;
        });
        Ok(McpServerHandle {
            addr: bound,
            shutdown,
            join,
        })
    }

    pub async fn serve_ephemeral(self) -> anyhow::Result<McpServerHandle> {
        self.serve(SocketAddr::from(([127, 0, 0, 1], 0))).await
    }
}

async fn oauth_metadata(State(state): State<AppState>) -> impl IntoResponse {
    let body = json!({
        "resource": format!("http://127.0.0.1:{}", state.bind_port)
    });
    (StatusCode::OK, axum::Json(body))
}

async fn mcp_endpoint(
    State(state): State<AppState>,
    method: Method,
    headers: HeaderMap,
    body: Body,
) -> Response {
    if let Err(response) = validate_origin(&headers, state.bind_port) {
        return response;
    }

    match method {
        Method::DELETE => handle_delete(&state, &headers).await,
        Method::GET => handle_get(&state, &headers).await,
        Method::POST => handle_post(state, headers, body).await,
        _ => status_response(StatusCode::METHOD_NOT_ALLOWED),
    }
}

async fn handle_delete(state: &AppState, headers: &HeaderMap) -> Response {
    let Some(session_id) = header_value(headers, SESSION_HEADER) else {
        return status_response(StatusCode::BAD_REQUEST);
    };
    let mut sessions = state.sessions.lock().await;
    if sessions.remove(&session_id).is_some() {
        status_response(StatusCode::OK)
    } else {
        status_response(StatusCode::NOT_FOUND)
    }
}

async fn handle_get(state: &AppState, headers: &HeaderMap) -> Response {
    if !accepts_event_stream(headers) {
        return status_response(StatusCode::METHOD_NOT_ALLOWED);
    }
    let Some(session_id) = header_value(headers, SESSION_HEADER) else {
        return status_response(StatusCode::BAD_REQUEST);
    };
    if let Err(response) = validate_protocol_version(headers) {
        return response;
    }
    let mut sessions = state.sessions.lock().await;
    let Some(session) = sessions.get_mut(&session_id) else {
        return status_response(StatusCode::NOT_FOUND);
    };
    session.last_used = Instant::now();
    let announce = !session.tool_list_announced;
    if announce {
        session.tool_list_announced = true;
    }
    drop(sessions);

    let mut body = String::from(": attached\n\n");
    if announce {
        let notification = json!({
            "jsonrpc": "2.0",
            "method": "notifications/tools/list_changed",
            "params": {}
        });
        body.push_str(&format!("event: message\ndata: {notification}\n\n"));
    }
    sse_response(body)
}

async fn handle_post(state: AppState, headers: HeaderMap, body: Body) -> Response {
    if let Err(response) = validate_accept(&headers) {
        return response;
    }
    if let Err(response) = validate_content_type(&headers) {
        return response;
    }

    let bytes = match axum::body::to_bytes(body, 16 * 1024 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return status_response(StatusCode::BAD_REQUEST),
    };
    let request: JsonRpcRequest = match serde_json::from_slice(&bytes) {
        Ok(request) => request,
        Err(error) => {
            return json_response(
                StatusCode::BAD_REQUEST,
                JsonRpcResponse::error(None, -32700, format!("parse error: {error}")),
                None,
            );
        }
    };

    let claimed = header_value(&headers, SESSION_HEADER);
    if let Some(session_id) = &claimed {
        let mut sessions = state.sessions.lock().await;
        let Some(session) = sessions.get_mut(session_id) else {
            return status_response(StatusCode::NOT_FOUND);
        };
        session.last_used = Instant::now();
        if let Err(response) = validate_protocol_version(&headers) {
            return response;
        }
    } else if !is_initialize(&request) {
        // Sessionless clients are allowed for simple request/response tooling and tests.
        if let Err(response) = validate_protocol_version_optional(&headers) {
            return response;
        }
    }

    if is_notification(&request) {
        return status_response(StatusCode::ACCEPTED);
    }

    let (response, new_session) = dispatch_request(&state, request, claimed.is_none()).await;
    let mut headers_out = HeaderMap::new();
    if let Some(session_id) = new_session {
        if let Ok(value) = HeaderValue::from_str(&session_id) {
            headers_out.insert(HeaderName::from_static(SESSION_HEADER), value);
        }
        headers_out.insert(
            HeaderName::from_static(PROTOCOL_HEADER),
            HeaderValue::from_static(PROTOCOL_VERSION),
        );
    }
    json_response(StatusCode::OK, response, Some(headers_out))
}

async fn dispatch_request(
    state: &AppState,
    request: JsonRpcRequest,
    assign_session: bool,
) -> (JsonRpcResponse, Option<String>) {
    let id = request.id.clone();
    match request.method.as_str() {
        "initialize" => {
            let mut session_id = None;
            if assign_session {
                session_id = Some(create_session(state).await);
            }
            (JsonRpcResponse::result(id, initialize_result()), session_id)
        }
        "ping" => (JsonRpcResponse::result(id, json!({})), None),
        "tools/list" => (JsonRpcResponse::result(id, tools_list_payload()), None),
        "tools/call" => {
            let params = request.params.unwrap_or_else(|| json!({}));
            let name = params
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            let arguments = params
                .get("arguments")
                .cloned()
                .unwrap_or_else(|| json!({}));
            if name.is_empty() {
                return (
                    JsonRpcResponse::error(id, -32602, "tools/call requires name"),
                    None,
                );
            }
            let result = call_tool(&state.backend, &name, arguments).await;
            (JsonRpcResponse::result(id, result), None)
        }
        other => (
            JsonRpcResponse::error(id, -32601, format!("method not found: {other}")),
            None,
        ),
    }
}

async fn create_session(state: &AppState) -> String {
    let mut sessions = state.sessions.lock().await;
    prune_sessions(&mut sessions);
    let session_id = Uuid::new_v4().hyphenated().to_string();
    sessions.insert(
        session_id.clone(),
        Session {
            last_used: Instant::now(),
            tool_list_announced: false,
        },
    );
    session_id
}

fn prune_sessions(sessions: &mut HashMap<String, Session>) {
    let cutoff = Instant::now()
        .checked_sub(SESSION_IDLE_LIMIT)
        .unwrap_or_else(Instant::now);
    sessions.retain(|_, session| session.last_used >= cutoff);
    while sessions.len() >= SESSION_COUNT_LIMIT {
        let oldest = sessions
            .iter()
            .min_by_key(|(_, session)| session.last_used)
            .map(|(id, _)| id.clone());
        if let Some(id) = oldest {
            sessions.remove(&id);
        } else {
            break;
        }
    }
}

fn validate_origin(headers: &HeaderMap, port: u16) -> Result<(), Response> {
    let Some(origin) = header_value(headers, "origin") else {
        return Ok(());
    };
    let allowed = [
        format!("http://127.0.0.1:{port}"),
        format!("http://localhost:{port}"),
        "http://127.0.0.1".to_owned(),
        "http://localhost".to_owned(),
        "null".to_owned(),
    ];
    if allowed.iter().any(|value| value == &origin) {
        Ok(())
    } else {
        Err(status_response(StatusCode::FORBIDDEN))
    }
}

fn validate_accept(headers: &HeaderMap) -> Result<(), Response> {
    let accept = header_value(headers, "accept").unwrap_or_default();
    if accept.contains("application/json") || accept.contains("*/*") || accept.is_empty() {
        Ok(())
    } else {
        Err(status_response(StatusCode::NOT_ACCEPTABLE))
    }
}

fn validate_content_type(headers: &HeaderMap) -> Result<(), Response> {
    let content_type = header_value(headers, "content-type").unwrap_or_default();
    if content_type.starts_with("application/json") || content_type.is_empty() {
        Ok(())
    } else {
        Err(status_response(StatusCode::UNSUPPORTED_MEDIA_TYPE))
    }
}

fn validate_protocol_version(headers: &HeaderMap) -> Result<(), Response> {
    match header_value(headers, PROTOCOL_HEADER).as_deref() {
        None | Some(PROTOCOL_VERSION) | Some("2025-03-26") => Ok(()),
        Some(_) => Err(status_response(StatusCode::BAD_REQUEST)),
    }
}

fn validate_protocol_version_optional(headers: &HeaderMap) -> Result<(), Response> {
    validate_protocol_version(headers)
}

fn accepts_event_stream(headers: &HeaderMap) -> bool {
    header_value(headers, "accept")
        .map(|value| value.contains("text/event-stream") || value.contains("*/*"))
        .unwrap_or(false)
}

fn header_value(headers: &HeaderMap, name: &str) -> Option<String> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned)
}

fn status_response(status: StatusCode) -> Response {
    Response::builder()
        .status(status)
        .body(Body::empty())
        .unwrap_or_else(|_| Response::new(Body::empty()))
}

fn json_response(
    status: StatusCode,
    body: JsonRpcResponse,
    extra_headers: Option<HeaderMap>,
) -> Response {
    let bytes = serde_json::to_vec(&body).unwrap_or_else(|_| b"{}".to_vec());
    let mut builder = Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "application/json");
    if let Some(headers) = extra_headers {
        for (name, value) in headers.iter() {
            builder = builder.header(name, value);
        }
    }
    builder
        .body(Body::from(bytes))
        .unwrap_or_else(|_| Response::new(Body::empty()))
}

fn sse_response(body: String) -> Response {
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "text/event-stream")
        .header(header::CACHE_CONTROL, "no-cache")
        .header(header::CONNECTION, "close")
        .body(Body::from(body))
        .unwrap_or_else(|_| Response::new(Body::empty()))
}
