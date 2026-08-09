use std::io;
use std::path::{Path, PathBuf};

use thiserror::Error;

use crate::coordinator::CoordinatorError;

pub type Result<T> = std::result::Result<T, ProjectError>;

#[derive(Debug, Error)]
pub enum ProjectError {
    #[error("{operation} failed for {path}: {source}")]
    Io {
        operation: &'static str,
        path: PathBuf,
        #[source]
        source: io::Error,
    },

    #[error("invalid project.json: {0}")]
    InvalidProject(#[source] palmier_core::ProjectDecodeError),

    #[error("project.json must contain at least one timeline")]
    EmptyProject,

    #[error("could not encode {context}: {source}")]
    Json {
        context: &'static str,
        #[source]
        source: serde_json::Error,
    },

    #[error("project package is not a directory: {0}")]
    NotPackage(PathBuf),

    #[error("source package does not exist: {0}")]
    MissingSourcePackage(PathBuf),

    #[error("destination must not be inside the source package")]
    DestinationInsideSource,

    #[error("invalid project-relative path: {0}")]
    InvalidRelativePath(PathBuf),

    #[error("external media path is not absolute: {0}")]
    RelativeExternalPath(PathBuf),

    #[error("invalid filename: {0}")]
    InvalidFilename(String),

    #[error("file is too large ({size} > {max_bytes} bytes)")]
    FileTooLarge { size: u64, max_bytes: u64 },

    #[error("operation was cancelled")]
    Cancelled,

    #[error("Linux renameat2 exchange failed for {path}: {source}")]
    AtomicExchange {
        path: PathBuf,
        #[source]
        source: io::Error,
    },

    #[error("background task failed: {0}")]
    Join(String),

    #[error(transparent)]
    Coordinator(#[from] CoordinatorError),
}

impl ProjectError {
    pub(crate) fn io(operation: &'static str, path: impl AsRef<Path>, source: io::Error) -> Self {
        Self::Io {
            operation,
            path: path.as_ref().to_path_buf(),
            source,
        }
    }

    pub(crate) fn json(context: &'static str, source: serde_json::Error) -> Self {
        Self::Json { context, source }
    }
}
