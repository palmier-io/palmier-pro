//! HTTP MCP server for Palmier Pro on Linux.
//!
//! Binds to `http://127.0.0.1:19789/mcp` by default and speaks streamable-HTTP
//! JSON-RPC for protocol version `2025-06-18`. Domain work goes through
//! [`McpEditorBackend`] so `palmier-service` can plug in later.

mod backend;
mod error;
mod json_util;
mod memory;
mod protocol;
mod server;
mod service_backend;
mod short_id;
mod tools;

pub use backend::{BoxFut, CreateProjectRequest, McpEditorBackend, ProjectSelector, SharedBackend};
pub use error::{BackendError, BackendResult};
pub use memory::InMemoryEditorBackend;
pub use protocol::{DEFAULT_PORT, PROTOCOL_VERSION, SERVER_NAME};
pub use server::{McpServer, McpServerHandle};
pub use service_backend::EditorServiceBackend;
pub use tools::{implemented_tools, tools_list_payload};
