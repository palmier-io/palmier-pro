use palmier_core::{MutationError, MutationErrorCode};
use serde_json::{Value, json};
use thiserror::Error;

pub type BackendResult<T> = Result<T, BackendError>;

#[derive(Debug, Error)]
pub enum BackendError {
    #[error("{0}")]
    Message(String),
    #[error(transparent)]
    Mutation(#[from] MutationError),
    #[error("no active project in this MCP session")]
    InactiveProject,
    #[error("ambiguous id '{ref_id}' matches {count} items")]
    AmbiguousId { ref_id: String, count: usize },
}

impl BackendError {
    pub fn message(message: impl Into<String>) -> Self {
        Self::Message(message.into())
    }

    pub fn code(&self) -> &'static str {
        match self {
            Self::InactiveProject => "inactive_project",
            Self::AmbiguousId { .. } => "ambiguous_id",
            Self::Mutation(error) => match error.code {
                MutationErrorCode::InvalidArgument => "invalid_argument",
                MutationErrorCode::InvalidFrame => "invalid_frame",
                MutationErrorCode::TimelineNotFound => "timeline_not_found",
                MutationErrorCode::TrackNotFound => "track_not_found",
                MutationErrorCode::ClipNotFound => "clip_not_found",
                MutationErrorCode::DuplicateId => "duplicate_id",
                MutationErrorCode::IncompatibleTrack => "incompatible_track",
                MutationErrorCode::Collision => "collision",
                MutationErrorCode::LinkNotEligible => "link_not_eligible",
                MutationErrorCode::MulticamAtomicity => "multicam_atomicity",
                MutationErrorCode::NoUndo => "no_undo",
                MutationErrorCode::NoRedo => "no_redo",
                MutationErrorCode::ArithmeticOverflow => "arithmetic_overflow",
            },
            Self::Message(_) => "tool_error",
        }
    }

    pub fn to_json(&self) -> Value {
        match self {
            Self::Mutation(error) => json!({
                "error": error.message,
                "code": self.code(),
                "details": error.details,
            }),
            Self::AmbiguousId { ref_id, count } => json!({
                "error": self.to_string(),
                "code": self.code(),
                "ref": ref_id,
                "matchCount": count,
            }),
            other => json!({
                "error": other.to_string(),
                "code": other.code(),
            }),
        }
    }
}
