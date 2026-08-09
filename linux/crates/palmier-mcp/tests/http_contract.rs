use std::sync::Arc;

use palmier_mcp::{
    EditorServiceBackend, InMemoryEditorBackend, McpServer, PROTOCOL_VERSION,
};
use palmier_service::EditorService;
use reqwest::header::{ACCEPT, CONTENT_TYPE, HeaderMap, HeaderValue};
use serde_json::{Value, json};

fn mcp_headers(session: Option<&str>) -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(
        ACCEPT,
        HeaderValue::from_static("application/json, text/event-stream"),
    );
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    headers.insert(
        "mcp-protocol-version",
        HeaderValue::from_static(PROTOCOL_VERSION),
    );
    if let Some(session) = session {
        headers.insert(
            "mcp-session-id",
            HeaderValue::from_str(session).expect("session id"),
        );
    }
    headers
}

async fn post_rpc(
    client: &reqwest::Client,
    base: &str,
    session: Option<&str>,
    body: Value,
) -> reqwest::Response {
    client
        .post(format!("{base}/mcp"))
        .headers(mcp_headers(session))
        .json(&body)
        .send()
        .await
        .expect("request")
}

async fn initialize(client: &reqwest::Client, base: &str) -> (String, Value) {
    let response = post_rpc(
        client,
        base,
        None,
        json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "palmier-mcp-tests", "version": "0.1.0"}
            }
        }),
    )
    .await;
    assert_eq!(response.status(), 200);
    let session = response
        .headers()
        .get("mcp-session-id")
        .expect("session header")
        .to_str()
        .expect("session ascii")
        .to_owned();
    let body: Value = response.json().await.expect("initialize json");
    assert_eq!(body["result"]["protocolVersion"], PROTOCOL_VERSION);
    let _ = post_rpc(
        client,
        base,
        Some(&session),
        json!({
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        }),
    )
    .await;
    (session, body)
}

async fn call_tool(
    client: &reqwest::Client,
    base: &str,
    session: &str,
    name: &str,
    arguments: Value,
) -> Value {
    let response = post_rpc(
        client,
        base,
        Some(session),
        json!({
            "jsonrpc": "2.0",
            "id": name,
            "method": "tools/call",
            "params": {
                "name": name,
                "arguments": arguments
            }
        }),
    )
    .await;
    assert_eq!(response.status(), 200, "tools/call {name}");
    let body: Value = response.json().await.expect("tool json");
    body["result"].clone()
}

fn tool_structured(result: &Value) -> Value {
    result
        .get("structuredContent")
        .cloned()
        .unwrap_or_else(|| json!({}))
}

#[tokio::test]
async fn shared_editor_service_mutation_readback_and_undo() {
    let directory = tempfile::tempdir().expect("temporary directory");
    let editor = EditorService::open_registry(directory.path().join("recent.json"))
        .await
        .expect("editor service");
    let backend = Arc::new(EditorServiceBackend::new(editor));
    let handle = McpServer::new(backend)
        .serve_ephemeral()
        .await
        .expect("bind");
    let base = format!("http://{}", handle.addr);
    let client = reqwest::Client::new();
    let (session, _) = initialize(&client, &base).await;

    let created = call_tool(
        &client,
        &base,
        &session,
        "manage_project",
        json!({"action": "create", "name": "Shared"}),
    )
    .await;
    assert_eq!(created["isError"], false);

    let added = call_tool(
        &client,
        &base,
        &session,
        "add_texts",
        json!({
            "entries": [{
                "content": "Shared state",
                "startFrame": 0,
                "endFrame": 30
            }]
        }),
    )
    .await;
    assert_eq!(added["isError"], false);

    let timeline = tool_structured(
        &call_tool(&client, &base, &session, "get_timeline", json!({})).await,
    );
    assert_eq!(
        timeline["timeline"]["tracks"][0]["clips"]
            .as_array()
            .map(Vec::len),
        Some(1)
    );

    let undone = call_tool(&client, &base, &session, "undo", json!({})).await;
    assert_eq!(undone["isError"], false);
    let timeline = tool_structured(
        &call_tool(&client, &base, &session, "get_timeline", json!({})).await,
    );
    assert_eq!(
        timeline["timeline"]["tracks"][0]["clips"]
            .as_array()
            .map(Vec::len),
        Some(0)
    );

    handle.shutdown().await;
}

#[tokio::test]
async fn discovery_lists_implemented_tools() {
    let backend = InMemoryEditorBackend::shared();
    let handle = McpServer::new(backend)
        .serve_ephemeral()
        .await
        .expect("bind");
    let base = format!("http://{}", handle.addr);
    let client = reqwest::Client::new();
    let (session, _) = initialize(&client, &base).await;

    let response = post_rpc(
        &client,
        &base,
        Some(&session),
        json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list"
        }),
    )
    .await;
    assert_eq!(response.status(), 200);
    let body: Value = response.json().await.expect("list json");
    let tools = body["result"]["tools"].as_array().expect("tools array");
    let names: Vec<&str> = tools
        .iter()
        .filter_map(|tool| tool.get("name").and_then(Value::as_str))
        .collect();
    for expected in [
        "manage_project",
        "get_timeline",
        "add_clips",
        "undo",
        "export_project",
        "apply_color",
        "add_texts",
        "list_models",
        "generate_video",
    ] {
        assert!(names.contains(&expected), "missing {expected}");
    }
    handle.shutdown().await;
}

#[tokio::test]
async fn mutation_readback_and_undo() {
    let backend = InMemoryEditorBackend::shared();
    let handle = McpServer::new(backend)
        .serve_ephemeral()
        .await
        .expect("bind");
    let base = format!("http://{}", handle.addr);
    let client = reqwest::Client::new();
    let (session, _) = initialize(&client, &base).await;

    let created = tool_structured(
        &call_tool(
            &client,
            &base,
            &session,
            "manage_project",
            json!({"action": "create", "name": "Contract", "fps": 30}),
        )
        .await,
    );
    assert_eq!(created["name"], "Contract");

    let imported = tool_structured(
        &call_tool(
            &client,
            &base,
            &session,
            "import_media",
            json!({
                "source": {"path": "/tmp/clip.mp4"},
                "name": "Clip"
            }),
        )
        .await,
    );
    let media_ref = imported["mediaRef"].as_str().expect("mediaRef");

    let added = tool_structured(
        &call_tool(
            &client,
            &base,
            &session,
            "add_clips",
            json!({
                "entries": [{
                    "mediaRef": media_ref,
                    "trackIndex": 0,
                    "startFrame": 0,
                    "endFrame": 60
                }]
            }),
        )
        .await,
    );
    assert_eq!(added["status"], "applied");
    assert!(!added["createdClipIds"].as_array().unwrap().is_empty());

    let timeline =
        tool_structured(&call_tool(&client, &base, &session, "get_timeline", json!({})).await);
    let clips = timeline["tracks"][0]["clips"].as_array().expect("clips");
    assert_eq!(clips.len(), 1);
    assert_eq!(clips[0]["durationFrames"], 60);

    let undone = tool_structured(&call_tool(&client, &base, &session, "undo", json!({})).await);
    assert_eq!(undone["status"], "undone");

    let timeline_after =
        tool_structured(&call_tool(&client, &base, &session, "get_timeline", json!({})).await);
    let clips_after = timeline_after["tracks"][0]["clips"]
        .as_array()
        .expect("clips after undo");
    assert!(clips_after.is_empty());

    handle.shutdown().await;
}

#[tokio::test]
async fn invalid_input_and_inactive_project() {
    let backend = InMemoryEditorBackend::shared();
    let handle = McpServer::new(backend)
        .serve_ephemeral()
        .await
        .expect("bind");
    let base = format!("http://{}", handle.addr);
    let client = reqwest::Client::new();
    let (session, _) = initialize(&client, &base).await;

    let inactive = call_tool(&client, &base, &session, "get_timeline", json!({})).await;
    assert_eq!(inactive["isError"], true);
    assert_eq!(tool_structured(&inactive)["code"], "inactive_project");

    let _ = call_tool(
        &client,
        &base,
        &session,
        "manage_project",
        json!({"action": "create", "name": "Validation"}),
    )
    .await;

    let invalid = call_tool(
        &client,
        &base,
        &session,
        "add_clips",
        json!({
            "entries": [{
                "mediaRef": "missing-media",
                "startFrame": 0
            }]
        }),
    )
    .await;
    assert_eq!(invalid["isError"], true);

    let bad_window = call_tool(
        &client,
        &base,
        &session,
        "get_timeline",
        json!({"startFrame": 10, "endFrame": 10}),
    )
    .await;
    assert_eq!(bad_window["isError"], true);

    handle.shutdown().await;
}

#[tokio::test]
async fn session_lifecycle_and_sse_attach() {
    let backend = InMemoryEditorBackend::shared();
    let handle = McpServer::new(backend)
        .serve_ephemeral()
        .await
        .expect("bind");
    let base = format!("http://{}", handle.addr);
    let client = reqwest::Client::new();
    let (session, _) = initialize(&client, &base).await;

    let get = client
        .get(format!("{base}/mcp"))
        .header(ACCEPT, "text/event-stream")
        .header("mcp-session-id", &session)
        .header("mcp-protocol-version", PROTOCOL_VERSION)
        .send()
        .await
        .expect("get");
    assert_eq!(get.status(), 200);
    assert!(
        get.headers()
            .get(CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .is_some_and(|value| value.starts_with("text/event-stream"))
    );
    let text = get.text().await.expect("sse body");
    assert!(text.contains("tools/list_changed"));

    let deleted = client
        .delete(format!("{base}/mcp"))
        .header("mcp-session-id", &session)
        .send()
        .await
        .expect("delete");
    assert_eq!(deleted.status(), 200);

    let stale = post_rpc(
        &client,
        &base,
        Some(&session),
        json!({
            "jsonrpc": "2.0",
            "id": 9,
            "method": "tools/list"
        }),
    )
    .await;
    assert_eq!(stale.status(), 404);

    let forbidden = client
        .post(format!("{base}/mcp"))
        .header(ACCEPT, "application/json")
        .header(CONTENT_TYPE, "application/json")
        .header("origin", "https://evil.example")
        .json(&json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "evil", "version": "0"}
            }
        }))
        .send()
        .await
        .expect("forbidden");
    assert_eq!(forbidden.status(), 403);

    handle.shutdown().await;
}

#[tokio::test]
async fn short_ids_round_trip_in_mutations() {
    let backend = InMemoryEditorBackend::shared();
    let handle = McpServer::new(backend)
        .serve_ephemeral()
        .await
        .expect("bind");
    let base = format!("http://{}", handle.addr);
    let client = reqwest::Client::new();
    let (session, _) = initialize(&client, &base).await;
    let _ = call_tool(
        &client,
        &base,
        &session,
        "manage_project",
        json!({"action": "create", "name": "ShortIds"}),
    )
    .await;
    let imported = tool_structured(
        &call_tool(
            &client,
            &base,
            &session,
            "import_media",
            json!({"source": {"path": "/tmp/a.mp4"}, "name": "A"}),
        )
        .await,
    );
    let short_media = imported["mediaRef"].as_str().expect("short media");
    assert!(short_media.len() < 36);

    let added = tool_structured(
        &call_tool(
            &client,
            &base,
            &session,
            "add_clips",
            json!({
                "entries": [{
                    "mediaRef": short_media,
                    "trackIndex": 0,
                    "startFrame": 0,
                    "endFrame": 30
                }]
            }),
        )
        .await,
    );
    let short_clip = added["createdClipIds"][0].as_str().expect("clip");
    let removed = call_tool(
        &client,
        &base,
        &session,
        "remove_clips",
        json!({"clipIds": [short_clip]}),
    )
    .await;
    assert_eq!(removed["isError"], false);

    let timeline =
        tool_structured(&call_tool(&client, &base, &session, "get_timeline", json!({})).await);
    assert!(
        timeline["tracks"][0]["clips"]
            .as_array()
            .map(|clips| clips.is_empty())
            .unwrap_or(false)
    );

    handle.shutdown().await;
}
