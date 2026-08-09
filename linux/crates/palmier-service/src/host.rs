use std::sync::Arc;

use crate::service::EditorService;

/// Host surface that MCP (and other frontends) can bind against.
///
/// Implementors expose the shared [`EditorService`] so UI and MCP submit the
/// same typed `EditorCommand` values and receive the same receipts.
pub trait EditorServiceHost: Send + Sync {
    fn editor_service(&self) -> &EditorService;
}

impl EditorServiceHost for EditorService {
    fn editor_service(&self) -> &EditorService {
        self
    }
}

impl EditorServiceHost for Arc<EditorService> {
    fn editor_service(&self) -> &EditorService {
        self.as_ref()
    }
}
