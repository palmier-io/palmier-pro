use palmier_generation::GenerationError;
use palmier_service::ServiceError;
use serde::Serialize;
use thiserror::Error;

pub type AppResult<T> = Result<T, AppError>;

#[derive(Debug, Error)]
pub enum AppError {
    #[error(transparent)]
    Service(#[from] ServiceError),

    #[error(transparent)]
    Generation(#[from] GenerationError),

    #[error(transparent)]
    Media(#[from] palmier_media::MediaError),

    #[error(transparent)]
    Project(#[from] palmier_project::ProjectError),

    #[error("{0}")]
    Message(String),
}

impl AppError {
    pub fn message(message: impl Into<String>) -> Self {
        Self::Message(message.into())
    }
}

impl Serialize for AppError {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&self.to_string())
    }
}
