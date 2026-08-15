mod commands;
mod dto;
mod error;
mod map;
mod state;

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use palmier_generation::GenerationService;
use palmier_mcp::{DEFAULT_PORT, EditorServiceBackend, McpServer, SharedBackend};
use palmier_service::EditorService;
use tauri::Manager;
use tracing_subscriber::EnvFilter;

use crate::state::AppState;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .try_init();

    let generation = Arc::new(
        GenerationService::with_keyring(default_stage_dir())
            .expect("initialize Secret Service generation"),
    );

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_shell::init())
        .setup(move |app| {
            let editor = tauri::async_runtime::block_on(EditorService::open_default_registry())
                .map_err(|error| {
                    Box::<dyn std::error::Error>::from(format!("open editor registry: {error}"))
                })?;
            let stage_dir = default_stage_dir();
            std::fs::create_dir_all(&stage_dir)?;
            let state = Arc::new(AppState::new(editor.clone(), generation, stage_dir));
            app.manage(state.clone());
            tauri::async_runtime::spawn(async move {
                start_mcp_server(state, editor).await;
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::editor_bootstrap,
            commands::create_project,
            commands::open_project,
            commands::import_media,
            commands::import_media_dialog,
            commands::persist_project,
            commands::save_provider_settings,
            commands::start_generation,
            commands::list_generation_jobs,
            commands::start_export,
            commands::list_export_jobs,
            commands::cancel_export,
            commands::commit_edit,
            commands::preview_edit,
            commands::get_project,
            commands::close_project,
            commands::decode_preview_frame,
            commands::render_preview_frame,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Palmier Pro");
}

async fn start_mcp_server(state: Arc<AppState>, editor: EditorService) {
    let backend: SharedBackend = Arc::new(EditorServiceBackend::with_generation(
        editor,
        Arc::clone(&state.generation),
    ));
    let server = McpServer::new(backend);
    let addr = SocketAddr::from(([127, 0, 0, 1], DEFAULT_PORT));
    match server.serve(addr).await {
        Ok(handle) => {
            tracing::info!(%addr, "MCP server listening");
            *state.mcp.lock().await = Some(handle);
        }
        Err(error) => {
            tracing::warn!(error = %error, %addr, "MCP server failed to start");
        }
    }
}

fn default_stage_dir() -> PathBuf {
    if let Some(cache) = std::env::var_os("XDG_CACHE_HOME") {
        return PathBuf::from(cache).join("palmier").join("generation");
    }
    if let Some(home) = std::env::var_os("HOME") {
        return PathBuf::from(home)
            .join(".cache")
            .join("palmier")
            .join("generation");
    }
    PathBuf::from("palmier-generation")
}
