use std::path::PathBuf;

use thiserror::Error;

pub type Result<T> = std::result::Result<T, GenerationError>;

#[derive(Debug, Error)]
pub enum GenerationError {
    #[error("model not found: {0}")]
    ModelNotFound(String),

    #[error("invalid generation request: {0}")]
    InvalidRequest(String),

    #[error(
        "provider credential is missing for {provider}. Store it in the Linux Secret Service under service palmier-pro, key {key}"
    )]
    CredentialMissing { provider: String, key: String },

    #[error(
        "Linux Secret Service is unavailable for key {key}. Install and unlock a Secret Service provider such as gnome-keyring or KWallet, then store the credential under service palmier-pro. {detail}"
    )]
    CredentialStoreUnavailable { key: String, detail: String },

    #[error("credential store failed for key {key}: {detail}")]
    CredentialStore { key: String, detail: String },

    #[error("HTTP request failed: {0}")]
    Http(String),

    #[error("provider returned status {status}: {body}")]
    ProviderStatus { status: u16, body: String },

    #[error("provider response was invalid: {0}")]
    ProviderResponse(String),

    #[error("job not found: {0}")]
    JobNotFound(String),

    #[error("job is not resumable: {0}")]
    NotResumable(String),

    #[error("generation was cancelled")]
    Cancelled,

    #[error("download exceeded the {max_bytes} byte limit")]
    DownloadTooLarge { max_bytes: u64 },

    #[error("refusing download from disallowed URL: {0}")]
    UnsafeDownloadUrl(String),

    #[error("reference upload is not implemented for {0}")]
    ReferenceUploadStub(String),

    #[error("I/O failed for {path:?}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("catalog is invalid: {0}")]
    Catalog(String),
}
