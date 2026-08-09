use palmier_core::MutationError;
use palmier_project::{CoordinatorError, ProjectError};
use thiserror::Error;
use uuid::Uuid;

pub type Result<T> = std::result::Result<T, ServiceError>;

#[derive(Debug, Error)]
pub enum ServiceError {
    #[error("project not found: {0}")]
    ProjectNotFound(Uuid),

    #[error("project is closed: {0}")]
    ProjectClosed(Uuid),

    #[error("revision mismatch for {project_id}: expected {expected}, actual {actual}")]
    RevisionMismatch {
        project_id: Uuid,
        expected: u64,
        actual: u64,
    },

    #[error("project has no saved path")]
    MissingProjectPath,

    #[error("media support is disabled (enable the `media` feature)")]
    MediaDisabled,

    #[error("export job not found: {0}")]
    ExportJobNotFound(Uuid),

    #[error(transparent)]
    Mutation(#[from] MutationError),

    #[error(transparent)]
    Project(#[from] ProjectError),

    #[error(transparent)]
    Coordinator(#[from] CoordinatorError),

    #[cfg(feature = "media")]
    #[error(transparent)]
    Media(#[from] palmier_media::MediaError),

    #[error("background task failed: {0}")]
    Join(String),
}
