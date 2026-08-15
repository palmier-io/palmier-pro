use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use palmier_generation::GenerationService;
use palmier_mcp::McpServerHandle;
use palmier_media::PreparedProjectRender;
use palmier_service::EditorService;
use tokio::sync::Mutex;
use uuid::Uuid;

use crate::dto::UiExportJob;

pub struct RenderCacheEntry {
    pub revision: u64,
    pub width: u32,
    pub height: u32,
    pub render: Arc<PreparedProjectRender>,
}

pub struct AppState {
    pub editor: EditorService,
    pub generation: Arc<GenerationService>,
    pub generation_assets: Mutex<HashMap<String, String>>,
    pub generation_projects: Mutex<HashMap<String, Uuid>>,
    pub export_jobs: Mutex<HashMap<String, UiExportJob>>,
    pub render_cache: Mutex<HashMap<Uuid, RenderCacheEntry>>,
    pub mcp: Mutex<Option<McpServerHandle>>,
    pub stage_dir: PathBuf,
}

impl AppState {
    pub fn new(
        editor: EditorService,
        generation: Arc<GenerationService>,
        stage_dir: PathBuf,
    ) -> Self {
        Self {
            editor,
            generation,
            generation_assets: Mutex::new(HashMap::new()),
            generation_projects: Mutex::new(HashMap::new()),
            export_jobs: Mutex::new(HashMap::new()),
            render_cache: Mutex::new(HashMap::new()),
            mcp: Mutex::new(None),
            stage_dir,
        }
    }
}
