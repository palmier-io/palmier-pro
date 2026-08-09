use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use reqwest::Client;
use tokio::sync::{Notify, RwLock};
use tokio_util::sync::CancellationToken;

use crate::catalog::{ModelCatalog, ProviderKind};
use crate::credentials::{CredentialStore, require_provider_credential};
use crate::download::{DownloadPolicy, download_bounded, staged_result_path};
use crate::error::{GenerationError, Result};
use crate::http::{HttpClient, ReqwestHttpClient};
use crate::job::{
    GenerationJob, GenerationRequest, JobRuntime, JobState, PollConfig, ProviderHandle,
    ProviderPoll,
};
use crate::providers::{FalAdapter, ProviderAdapter, ReplicateAdapter, build_provider_input};

#[derive(Clone)]
struct LiveJob {
    snapshot: GenerationJob,
    runtime: JobRuntime,
}

pub struct GenerationService {
    catalog: Arc<ModelCatalog>,
    credentials: Arc<dyn CredentialStore>,
    http: Arc<dyn HttpClient>,
    download_client: Client,
    fal: FalAdapter,
    replicate: ReplicateAdapter,
    poll: PollConfig,
    download_policy: DownloadPolicy,
    default_stage_dir: PathBuf,
    jobs: Arc<RwLock<HashMap<String, LiveJob>>>,
    notify: Arc<Notify>,
}

impl GenerationService {
    pub fn new(
        credentials: Arc<dyn CredentialStore>,
        http: Arc<dyn HttpClient>,
        stage_dir: PathBuf,
    ) -> Result<Self> {
        Ok(Self {
            catalog: Arc::new(ModelCatalog::bundled()?.clone()),
            credentials,
            http,
            download_client: Client::new(),
            fal: FalAdapter::new(),
            replicate: ReplicateAdapter::new(),
            poll: PollConfig::default(),
            download_policy: DownloadPolicy::default(),
            default_stage_dir: stage_dir,
            jobs: Arc::new(RwLock::new(HashMap::new())),
            notify: Arc::new(Notify::new()),
        })
    }

    pub fn with_adapters(
        credentials: Arc<dyn CredentialStore>,
        http: Arc<dyn HttpClient>,
        stage_dir: PathBuf,
        fal: FalAdapter,
        replicate: ReplicateAdapter,
        poll: PollConfig,
        download_policy: DownloadPolicy,
    ) -> Result<Self> {
        let mut service = Self::new(credentials, http, stage_dir)?;
        service.fal = fal;
        service.replicate = replicate;
        service.poll = poll;
        service.download_policy = download_policy;
        Ok(service)
    }

    pub fn with_keyring(stage_dir: PathBuf) -> Result<Self> {
        Self::new(
            Arc::new(crate::credentials::KeyringCredentialStore::new()),
            Arc::new(ReqwestHttpClient::new()?),
            stage_dir,
        )
    }

    pub fn catalog(&self) -> &ModelCatalog {
        &self.catalog
    }

    pub fn credentials(&self) -> &dyn CredentialStore {
        self.credentials.as_ref()
    }

    pub async fn can_generate(&self, model_id: &str) -> Result<bool> {
        let model = self.catalog.require(model_id)?;
        match require_provider_credential(self.credentials.as_ref(), model.provider) {
            Ok(_) => Ok(true),
            Err(GenerationError::CredentialMissing { .. }) => Ok(false),
            Err(error) => Err(error),
        }
    }

    pub async fn list_jobs(&self) -> Vec<GenerationJob> {
        self.jobs
            .read()
            .await
            .values()
            .map(|job| job.snapshot.clone())
            .collect()
    }

    pub async fn get_job(&self, job_id: &str) -> Result<GenerationJob> {
        self.jobs
            .read()
            .await
            .get(job_id)
            .map(|job| job.snapshot.clone())
            .ok_or_else(|| GenerationError::JobNotFound(job_id.to_owned()))
    }

    pub async fn cancel(&self, job_id: &str) -> Result<GenerationJob> {
        let (handle, provider, credential) = {
            let mut jobs = self.jobs.write().await;
            let live = jobs
                .get_mut(job_id)
                .ok_or_else(|| GenerationError::JobNotFound(job_id.to_owned()))?;
            if live.snapshot.state.is_terminal() {
                return Ok(live.snapshot.clone());
            }
            live.runtime.cancel.cancel();
            live.snapshot.state = JobState::Cancelled;
            live.snapshot.error = Some("cancelled".into());
            (
                live.snapshot.provider_handle.clone(),
                live.snapshot.provider,
                require_provider_credential(self.credentials.as_ref(), live.snapshot.provider).ok(),
            )
        };
        self.notify.notify_waiters();
        if let (Some(handle), Some(credential)) = (handle, credential) {
            let _ = self.cancel_provider(provider, &credential, &handle).await;
        }
        self.get_job(job_id).await
    }

    pub async fn start(&self, mut request: GenerationRequest) -> Result<GenerationJob> {
        let model = self.catalog.require(&request.model_id)?.clone();
        if !self.can_generate(&model.id).await? {
            let _ = require_provider_credential(self.credentials.as_ref(), model.provider)?;
        }
        if request.stage_dir.is_none() {
            request.stage_dir = Some(self.default_stage_dir.clone());
        }
        let job = GenerationJob::new(model.id.clone(), model.kind, model.provider, request);
        let cancel = CancellationToken::new();
        {
            let mut jobs = self.jobs.write().await;
            jobs.insert(
                job.id.clone(),
                LiveJob {
                    snapshot: job.clone(),
                    runtime: JobRuntime {
                        cancel: cancel.clone(),
                    },
                },
            );
        }
        self.notify.notify_waiters();
        self.spawn_runner(job.id.clone(), cancel);
        Ok(job)
    }

    pub async fn resume(&self, job_id: &str) -> Result<GenerationJob> {
        let cancel = {
            let mut jobs = self.jobs.write().await;
            let live = jobs
                .get_mut(job_id)
                .ok_or_else(|| GenerationError::JobNotFound(job_id.to_owned()))?;
            if live.snapshot.state.is_terminal() {
                return Ok(live.snapshot.clone());
            }
            if live.snapshot.provider_handle.is_none() && live.snapshot.state != JobState::Preparing
            {
                return Err(GenerationError::NotResumable(job_id.to_owned()));
            }
            live.runtime.cancel = CancellationToken::new();
            live.runtime.cancel.clone()
        };
        self.spawn_runner(job_id.to_owned(), cancel);
        self.get_job(job_id).await
    }

    pub async fn wait_until(
        &self,
        job_id: &str,
        predicate: impl Fn(&GenerationJob) -> bool,
        timeout: Duration,
    ) -> Result<GenerationJob> {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let job = self.get_job(job_id).await?;
            if predicate(&job) {
                return Ok(job);
            }
            if tokio::time::Instant::now() >= deadline {
                return Err(GenerationError::InvalidRequest(format!(
                    "timed out waiting for job {job_id}"
                )));
            }
            let notified = self.notify.notified();
            tokio::select! {
                () = notified => {}
                () = tokio::time::sleep(Duration::from_millis(50)) => {}
            }
        }
    }

    fn spawn_runner(&self, job_id: String, cancel: CancellationToken) {
        let service = ServiceHandle {
            catalog: Arc::clone(&self.catalog),
            credentials: Arc::clone(&self.credentials),
            http: Arc::clone(&self.http),
            download_client: self.download_client.clone(),
            fal: self.fal.clone(),
            replicate: self.replicate.clone(),
            poll: self.poll,
            download_policy: self.download_policy,
            jobs: Arc::clone(&self.jobs),
            notify: Arc::clone(&self.notify),
        };
        tokio::spawn(async move {
            if let Err(error) = service.run_job(&job_id, cancel).await {
                if !matches!(error, GenerationError::Cancelled) {
                    service.fail_job(&job_id, error.to_string()).await;
                }
            }
        });
    }

    async fn cancel_provider(
        &self,
        provider: ProviderKind,
        credential: &str,
        handle: &ProviderHandle,
    ) -> Result<()> {
        match provider {
            ProviderKind::Fal => {
                self.fal
                    .cancel(self.http.as_ref(), credential, handle)
                    .await
            }
            ProviderKind::Replicate => {
                self.replicate
                    .cancel(self.http.as_ref(), credential, handle)
                    .await
            }
        }
    }
}

struct ServiceHandle {
    catalog: Arc<ModelCatalog>,
    credentials: Arc<dyn CredentialStore>,
    http: Arc<dyn HttpClient>,
    download_client: Client,
    fal: FalAdapter,
    replicate: ReplicateAdapter,
    poll: PollConfig,
    download_policy: DownloadPolicy,
    jobs: Arc<RwLock<HashMap<String, LiveJob>>>,
    notify: Arc<Notify>,
}

impl ServiceHandle {
    async fn run_job(&self, job_id: &str, cancel: CancellationToken) -> Result<()> {
        let job = self.snapshot(job_id).await?;
        if cancel.is_cancelled() || job.state == JobState::Cancelled {
            self.set_state(
                job_id,
                JobState::Cancelled,
                None,
                None,
                None,
                Some("cancelled".into()),
            )
            .await;
            return Err(GenerationError::Cancelled);
        }

        let model = self.catalog.require(&job.model_id)?.clone();
        let credential = require_provider_credential(self.credentials.as_ref(), model.provider)?;

        let mut request = job.request.clone();
        if !request.reference_paths.is_empty() {
            for path in request.reference_paths.clone() {
                if cancel.is_cancelled() {
                    return self.mark_cancelled(job_id).await;
                }
                let uploaded = self
                    .upload_reference(model.provider, &credential, &path)
                    .await?;
                request.reference_urls.push(uploaded);
            }
            request.reference_paths.clear();
            self.patch_request(job_id, request.clone()).await;
        }

        let handle = if let Some(existing) = job.provider_handle.clone() {
            existing
        } else {
            let input = build_provider_input(&model, &request)?;
            if cancel.is_cancelled() {
                return self.mark_cancelled(job_id).await;
            }
            self.set_state(job_id, JobState::Running, None, None, None, None)
                .await;
            let submitted = self
                .submit(model.provider, &credential, &model, &input)
                .await?;
            self.set_state(
                job_id,
                JobState::Running,
                Some(submitted.clone()),
                None,
                None,
                None,
            )
            .await;
            submitted
        };

        let result_urls = self
            .poll_until_done(job_id, &model, &credential, &handle, &cancel)
            .await?;

        if cancel.is_cancelled() {
            return self.mark_cancelled(job_id).await;
        }

        self.set_state(
            job_id,
            JobState::Downloading,
            Some(handle),
            Some(result_urls.clone()),
            None,
            None,
        )
        .await;

        let stage_dir = request
            .stage_dir
            .clone()
            .unwrap_or_else(|| PathBuf::from("."));
        tokio::fs::create_dir_all(&stage_dir)
            .await
            .map_err(|source| GenerationError::Io {
                path: stage_dir.clone(),
                source,
            })?;

        let mut staged = Vec::with_capacity(result_urls.len());
        for (index, url) in result_urls.iter().enumerate() {
            if cancel.is_cancelled() {
                return self.mark_cancelled(job_id).await;
            }
            let path = staged_result_path(&stage_dir, job_id, index, &model.file_extension);
            download_bounded(
                &self.download_client,
                url,
                &path,
                self.download_policy,
                &cancel,
            )
            .await?;
            staged.push(path);
        }

        self.set_state(
            job_id,
            JobState::Ready,
            None,
            Some(result_urls),
            Some(staged),
            None,
        )
        .await;
        Ok(())
    }

    async fn poll_until_done(
        &self,
        job_id: &str,
        model: &crate::catalog::CatalogModel,
        credential: &str,
        handle: &ProviderHandle,
        cancel: &CancellationToken,
    ) -> Result<Vec<String>> {
        let mut delay = self.poll.initial_delay;
        for _ in 0..self.poll.max_attempts {
            if cancel.is_cancelled() {
                return Err(GenerationError::Cancelled);
            }
            let poll = self
                .poll_once(model.provider, credential, model, handle)
                .await?;
            match poll {
                ProviderPoll::Pending => {
                    tokio::select! {
                        () = cancel.cancelled() => return Err(GenerationError::Cancelled),
                        () = tokio::time::sleep(delay) => {}
                    }
                    delay = (delay * 2).min(self.poll.max_delay);
                }
                ProviderPoll::Succeeded { result_urls } => return Ok(result_urls),
                ProviderPoll::Failed { message } => {
                    self.fail_job(job_id, message.clone()).await;
                    return Err(GenerationError::ProviderResponse(message));
                }
                ProviderPoll::Cancelled => {
                    self.mark_cancelled(job_id).await?;
                    return Err(GenerationError::Cancelled);
                }
            }
        }
        Err(GenerationError::ProviderResponse(
            "provider polling exceeded max attempts".into(),
        ))
    }

    async fn submit(
        &self,
        provider: ProviderKind,
        credential: &str,
        model: &crate::catalog::CatalogModel,
        input: &serde_json::Value,
    ) -> Result<ProviderHandle> {
        match provider {
            ProviderKind::Fal => {
                self.fal
                    .submit(self.http.as_ref(), credential, model, input)
                    .await
            }
            ProviderKind::Replicate => {
                self.replicate
                    .submit(self.http.as_ref(), credential, model, input)
                    .await
            }
        }
    }

    async fn poll_once(
        &self,
        provider: ProviderKind,
        credential: &str,
        model: &crate::catalog::CatalogModel,
        handle: &ProviderHandle,
    ) -> Result<ProviderPoll> {
        match provider {
            ProviderKind::Fal => {
                self.fal
                    .poll(self.http.as_ref(), credential, model, handle)
                    .await
            }
            ProviderKind::Replicate => {
                self.replicate
                    .poll(self.http.as_ref(), credential, model, handle)
                    .await
            }
        }
    }

    async fn upload_reference(
        &self,
        provider: ProviderKind,
        credential: &str,
        path: &std::path::Path,
    ) -> Result<String> {
        match provider {
            ProviderKind::Fal => {
                self.fal
                    .upload_reference(self.http.as_ref(), credential, path)
                    .await
            }
            ProviderKind::Replicate => {
                self.replicate
                    .upload_reference(self.http.as_ref(), credential, path)
                    .await
            }
        }
    }

    async fn snapshot(&self, job_id: &str) -> Result<GenerationJob> {
        self.jobs
            .read()
            .await
            .get(job_id)
            .map(|job| job.snapshot.clone())
            .ok_or_else(|| GenerationError::JobNotFound(job_id.to_owned()))
    }

    async fn patch_request(&self, job_id: &str, request: GenerationRequest) {
        if let Some(job) = self.jobs.write().await.get_mut(job_id) {
            job.snapshot.request = request;
        }
        self.notify.notify_waiters();
    }

    async fn set_state(
        &self,
        job_id: &str,
        state: JobState,
        handle: Option<ProviderHandle>,
        result_urls: Option<Vec<String>>,
        staged_paths: Option<Vec<PathBuf>>,
        error: Option<String>,
    ) {
        if let Some(job) = self.jobs.write().await.get_mut(job_id) {
            if job.snapshot.state == JobState::Cancelled && state != JobState::Cancelled {
                return;
            }
            job.snapshot.state = state;
            if let Some(handle) = handle {
                job.snapshot.provider_handle = Some(handle);
            }
            if let Some(result_urls) = result_urls {
                job.snapshot.result_urls = result_urls;
            }
            if let Some(staged_paths) = staged_paths {
                job.snapshot.staged_paths = staged_paths;
            }
            if error.is_some() {
                job.snapshot.error = error;
            } else if state == JobState::Ready {
                job.snapshot.error = None;
            }
        }
        self.notify.notify_waiters();
    }

    async fn fail_job(&self, job_id: &str, message: String) {
        self.set_state(job_id, JobState::Failed, None, None, None, Some(message))
            .await;
    }

    async fn mark_cancelled(&self, job_id: &str) -> Result<()> {
        self.set_state(
            job_id,
            JobState::Cancelled,
            None,
            None,
            None,
            Some("cancelled".into()),
        )
        .await;
        Err(GenerationError::Cancelled)
    }
}
