mod catalog;
mod credentials;
mod download;
mod error;
mod http;
mod job;
mod mcp;
mod providers;
mod service;

pub use catalog::{CATALOG_VERSION, CatalogModel, ModelCatalog, ModelKind, ProviderKind};
pub use credentials::{
    CredentialStore, FAL_API_KEY, KeyringCredentialStore, MemoryCredentialStore,
    REPLICATE_API_TOKEN, SERVICE_NAME, SharedCredentialStore, require_provider_credential,
};
pub use download::{DEFAULT_MAX_DOWNLOAD_BYTES, DownloadPolicy};
pub use error::{GenerationError, Result};
pub use http::{HttpClient, HttpRequest, HttpResponse, ReqwestHttpClient, SharedHttpClient};
pub use job::{
    GenerationJob, GenerationRequest, JobState, PollConfig, ProviderHandle, ProviderPoll,
};
pub use mcp::{
    GenerateAudioParams, GenerateImageParams, GenerateVideoParams, ModelSummary,
    SharedGenerationService, UpscaleMediaParams, generate_audio, generate_image, generate_video,
    list_models, list_models_filtered, upscale_media,
};
pub use providers::{FalAdapter, ProviderAdapter, ReplicateAdapter, build_provider_input};
pub use service::GenerationService;
