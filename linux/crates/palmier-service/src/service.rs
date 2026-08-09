use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use palmier_core::{
    ClipType, EditorCommand, MediaImportInput, MediaManifestEntry, MediaSource, new_id,
};
use palmier_project::{
    ImportRoot, InstallNamePolicy, ProjectEntry, ProjectPackageStore, RecentProjectRegistry,
    plan_imports,
};
use tokio::sync::Mutex;
use uuid::Uuid;

use crate::actor::{ProjectActor, SharedProjectActor};
use crate::error::{Result, ServiceError};
use crate::snapshot::{
    BootstrapPayload, EditResult, ImportResult, ImportedMediaEntry, OpenProjectSummary,
    PreviewResult, ProjectView,
};

#[cfg(feature = "media")]
use crate::snapshot::ExportJobSummary;
#[cfg(feature = "media")]
use palmier_media::{
    DecodedFrame, ExportFrameSource, ExportJobHandle, ExportJobId, ExportQueue, ExportRequest,
    PausedFrameRequest, probe_media,
};

/// Process-wide editor facade. UI and MCP share one instance.
#[derive(Clone)]
pub struct EditorService {
    inner: Arc<ServiceInner>,
}

struct ServiceInner {
    store: ProjectPackageStore,
    registry: RecentProjectRegistry,
    projects: Mutex<HashMap<Uuid, SharedProjectActor>>,
    #[cfg(feature = "media")]
    export_queue: Mutex<Option<ExportQueue>>,
    #[cfg(feature = "media")]
    export_jobs: Mutex<HashMap<Uuid, TrackedExportJob>>,
}

#[cfg(feature = "media")]
struct TrackedExportJob {
    project_id: Uuid,
    handle: ExportJobHandle,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImportMode {
    /// Register absolute external media references in the manifest.
    ExternalRefs,
    /// Copy into the project package media directory when a path is set.
    InstallIntoPackage,
}

impl EditorService {
    pub async fn open_registry(registry_path: impl AsRef<Path>) -> Result<Self> {
        let registry = RecentProjectRegistry::open(registry_path).await?;
        Ok(Self::with_parts(ProjectPackageStore::new(), registry))
    }

    pub async fn open_default_registry() -> Result<Self> {
        let registry = RecentProjectRegistry::open_default().await?;
        Ok(Self::with_parts(ProjectPackageStore::new(), registry))
    }

    pub fn with_parts(store: ProjectPackageStore, registry: RecentProjectRegistry) -> Self {
        Self {
            inner: Arc::new(ServiceInner {
                store,
                registry,
                projects: Mutex::new(HashMap::new()),
                #[cfg(feature = "media")]
                export_queue: Mutex::new(None),
                #[cfg(feature = "media")]
                export_jobs: Mutex::new(HashMap::new()),
            }),
        }
    }

    pub fn store(&self) -> &ProjectPackageStore {
        &self.inner.store
    }

    pub fn registry(&self) -> &RecentProjectRegistry {
        &self.inner.registry
    }

    pub async fn create_project(&self) -> Result<ProjectView> {
        let id = Uuid::new_v4();
        let actor = ProjectActor::new_empty(id)?;
        let view = actor.view().await;
        self.inner.projects.lock().await.insert(id, actor);
        Ok(view)
    }

    pub async fn open_project(&self, path: impl AsRef<Path>) -> Result<ProjectView> {
        let path = path.as_ref().to_path_buf();
        let opened = self.inner.store.open(&path).await?;
        let entry = self.inner.registry.register(&path).await?;
        let actor = ProjectActor::from_opened(entry.id, opened)?;
        let view = actor.view().await;
        self.inner.projects.lock().await.insert(entry.id, actor);
        Ok(view)
    }

    pub async fn close_project(&self, project_id: Uuid) -> Result<()> {
        let actor = self.actor(project_id).await?;
        actor.begin_close().await;
        self.inner.projects.lock().await.remove(&project_id);
        Ok(())
    }

    pub async fn project_view(&self, project_id: Uuid) -> Result<ProjectView> {
        Ok(self.actor(project_id).await?.view().await)
    }

    pub async fn list_open_projects(&self) -> Vec<OpenProjectSummary> {
        let projects = self.inner.projects.lock().await;
        let mut summaries = Vec::with_capacity(projects.len());
        for actor in projects.values() {
            summaries.push(actor.summary().await);
        }
        summaries.sort_by_key(|summary| summary.project_id);
        summaries
    }

    pub async fn list_recent_projects(&self) -> Vec<ProjectEntry> {
        self.inner.registry.sorted_entries().await
    }

    pub async fn bootstrap(&self) -> Result<BootstrapPayload> {
        Ok(BootstrapPayload {
            recent_projects: self.list_recent_projects().await,
            open_projects: self.list_open_projects().await,
        })
    }

    pub async fn save_project(&self, project_id: Uuid) -> Result<OpenProjectSummary> {
        let actor = self.actor(project_id).await?;
        let (path, snapshot, revision) = actor.take_save_snapshot().await?;
        let path = path.ok_or(ServiceError::MissingProjectPath)?;
        self.inner.store.save(&path, snapshot).await?;
        if actor.is_closed().await {
            return Err(ServiceError::ProjectClosed(project_id));
        }
        actor.mark_saved(path, revision).await
    }

    pub async fn save_project_as(
        &self,
        project_id: Uuid,
        destination: impl AsRef<Path>,
    ) -> Result<OpenProjectSummary> {
        let actor = self.actor(project_id).await?;
        let (source, snapshot, revision) = actor.take_save_snapshot().await?;
        let destination = destination.as_ref().to_path_buf();
        if let Some(source) = source {
            self.inner
                .store
                .save_as(&source, &destination, snapshot)
                .await?;
        } else {
            self.inner.store.save(&destination, snapshot).await?;
        }
        if actor.is_closed().await {
            return Err(ServiceError::ProjectClosed(project_id));
        }
        let summary = actor
            .update_path_after_save_as(destination.clone(), revision)
            .await?;
        let _ = self.inner.registry.register(&destination).await?;
        Ok(summary)
    }

    pub async fn preview_edit(
        &self,
        project_id: Uuid,
        expected_revision: u64,
        command: EditorCommand,
    ) -> Result<PreviewResult> {
        self.actor(project_id)
            .await?
            .preview(expected_revision, command)
            .await
    }

    pub async fn commit_edit(
        &self,
        project_id: Uuid,
        expected_revision: u64,
        command: EditorCommand,
    ) -> Result<EditResult> {
        self.actor(project_id)
            .await?
            .commit(expected_revision, command, true)
            .await
    }

    pub async fn undo(&self, project_id: Uuid, expected_revision: u64) -> Result<EditResult> {
        self.commit_edit(project_id, expected_revision, EditorCommand::Undo)
            .await
    }

    pub async fn redo(&self, project_id: Uuid, expected_revision: u64) -> Result<EditResult> {
        self.commit_edit(project_id, expected_revision, EditorCommand::Redo)
            .await
    }

    pub async fn import_local_files(
        &self,
        project_id: Uuid,
        paths: impl IntoIterator<Item = PathBuf>,
        mode: ImportMode,
        parent_folder_id: Option<String>,
    ) -> Result<ImportResult> {
        let roots = paths
            .into_iter()
            .map(|path| match &parent_folder_id {
                Some(folder_id) => ImportRoot::in_folder(path, folder_id.clone()),
                None => ImportRoot::new(path),
            })
            .collect::<Vec<_>>();
        let plan = plan_imports(roots).await?;
        let actor = self.actor(project_id).await?;

        let mut prepared = Vec::with_capacity(plan.files.len());
        for file in &plan.files {
            let probe = probe_import_file(&file.path, file.kind).await?;
            prepared.push((file.clone(), probe));
        }

        let package_path = actor.path().await;
        let install = matches!(mode, ImportMode::InstallIntoPackage);
        if install && package_path.is_none() {
            return Err(ServiceError::MissingProjectPath);
        }

        let installer = self.inner.store.media_installer();
        let mut installed_paths = HashMap::new();
        if install {
            let package_path = package_path.expect("checked above");
            for (file, _) in &prepared {
                let preferred_name = file
                    .path
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_else(|| file.name.clone());
                let installed = installer
                    .install_media_file(
                        &package_path,
                        &file.path,
                        &preferred_name,
                        InstallNamePolicy::Unique,
                        None,
                    )
                    .await?;
                installed_paths.insert(file.path.clone(), installed);
            }
        }

        let warnings = plan
            .warnings
            .iter()
            .map(|warning| format!("{}: {}", warning.path.display(), warning.message))
            .collect::<Vec<_>>();
        let rejected = plan.rejected_unsupported_names.clone();

        actor
            .with_session_mut(|state| {
                let mut manifest = state.session_mut().media_manifest().clone();
                let mut entries = Vec::with_capacity(prepared.len());
                for (file, probe) in prepared {
                    let asset_id = new_id();
                    let (source, installed, source_path) =
                        if let Some(installed) = installed_paths.get(&file.path) {
                            let relative = format!(
                                "{}/{}",
                                palmier_project::MEDIA_DIRECTORY_NAME,
                                installed.filename
                            );
                            (
                                MediaSource::Project {
                                    relative_path: relative,
                                },
                                true,
                                installed.path.clone(),
                            )
                        } else {
                            let absolute = file
                                .path
                                .canonicalize()
                                .unwrap_or_else(|_| file.path.clone());
                            (
                                MediaSource::External {
                                    absolute_path: absolute.display().to_string(),
                                },
                                false,
                                absolute,
                            )
                        };

                    let folder_id = match &file.parent {
                        palmier_project::ImportParent::ExistingFolder(id) => id.clone(),
                        palmier_project::ImportParent::PlannedFolder(_) => parent_folder_id.clone(),
                    };

                    let entry = MediaManifestEntry {
                        id: asset_id.clone(),
                        name: file.name.clone(),
                        media_type: file.kind,
                        source,
                        duration: probe.duration,
                        generation_input: None,
                        source_width: probe.width,
                        source_height: probe.height,
                        source_fps: probe.fps,
                        has_audio: probe.has_audio,
                        folder_id,
                        cached_remote_url: None,
                        cached_remote_url_expires_at: None,
                        generation_status: None,
                        import_input: Some(MediaImportInput {
                            source_url: None,
                            source_path: Some(file.path.display().to_string()),
                            created_at: None,
                        }),
                    };
                    manifest.entries.push(entry);
                    entries.push(ImportedMediaEntry {
                        asset_id,
                        name: file.name,
                        media_type: file.kind,
                        source_path,
                        duration: probe.duration,
                        installed,
                    });
                }
                state.session_mut().set_media_manifest(manifest);
                state.mark_dirty();
                Ok(ImportResult {
                    project_id,
                    revision: state.session().revision(),
                    dirty: true,
                    entries,
                    rejected_unsupported_names: rejected,
                    warnings,
                })
            })
            .await
    }

    #[cfg(feature = "media")]
    pub async fn ensure_export_queue(
        &self,
        max_pending: usize,
        max_concurrent: usize,
    ) -> Result<()> {
        let mut queue = self.inner.export_queue.lock().await;
        if queue.is_none() {
            *queue = Some(ExportQueue::ffmpeg(max_pending, max_concurrent)?);
        }
        Ok(())
    }

    #[cfg(feature = "media")]
    pub async fn start_export(
        &self,
        project_id: Uuid,
        request: ExportRequest,
        source: Arc<dyn ExportFrameSource>,
    ) -> Result<ExportJobId> {
        let _ = self.actor(project_id).await?;
        {
            let queue = self.inner.export_queue.lock().await;
            if queue.is_none() {
                drop(queue);
                self.ensure_export_queue(8, 1).await?;
            }
        }
        let handle = {
            let queue = self.inner.export_queue.lock().await;
            let queue = queue.as_ref().expect("export queue initialized");
            queue.submit(request, source)?
        };
        let job_id = handle.id();
        self.inner
            .export_jobs
            .lock()
            .await
            .insert(job_id.as_uuid(), TrackedExportJob { project_id, handle });
        Ok(job_id)
    }

    #[cfg(feature = "media")]
    pub async fn list_exports(&self) -> Vec<ExportJobSummary> {
        let jobs = self.inner.export_jobs.lock().await;
        jobs.iter()
            .map(|(job_id, tracked)| ExportJobSummary {
                job_id: *job_id,
                project_id: tracked.project_id,
                state: tracked.handle.state(),
            })
            .collect()
    }

    #[cfg(feature = "media")]
    pub async fn cancel_export(&self, job_id: Uuid) -> Result<()> {
        let jobs = self.inner.export_jobs.lock().await;
        let tracked = jobs
            .get(&job_id)
            .ok_or(ServiceError::ExportJobNotFound(job_id))?;
        tracked.handle.cancel();
        Ok(())
    }

    #[cfg(feature = "media")]
    pub async fn decode_paused_frame(&self, request: PausedFrameRequest) -> Result<DecodedFrame> {
        Ok(palmier_media::decode_paused_frame(request).await?)
    }

    #[cfg(not(feature = "media"))]
    pub async fn start_export_unavailable(&self) -> Result<()> {
        Err(ServiceError::MediaDisabled)
    }

    #[cfg(not(feature = "media"))]
    pub async fn decode_paused_frame_unavailable(&self) -> Result<()> {
        Err(ServiceError::MediaDisabled)
    }

    async fn actor(&self, project_id: Uuid) -> Result<SharedProjectActor> {
        self.inner
            .projects
            .lock()
            .await
            .get(&project_id)
            .cloned()
            .ok_or(ServiceError::ProjectNotFound(project_id))
    }
}

struct ImportProbe {
    duration: f64,
    width: Option<i32>,
    height: Option<i32>,
    fps: Option<f64>,
    has_audio: Option<bool>,
}

async fn probe_import_file(path: &Path, kind: ClipType) -> Result<ImportProbe> {
    #[cfg(feature = "media")]
    {
        match probe_media(path.to_path_buf()).await {
            Ok(probe) => {
                let duration = probe
                    .duration
                    .map(|time| {
                        let seconds = time.seconds().as_f64();
                        if seconds.is_finite() && seconds >= 0.0 {
                            seconds
                        } else {
                            0.0
                        }
                    })
                    .unwrap_or(0.0);
                let (width, height, fps) = probe
                    .video
                    .as_ref()
                    .map(|video| {
                        (
                            Some(i32::try_from(video.display_width).unwrap_or(0)),
                            Some(i32::try_from(video.display_height).unwrap_or(0)),
                            video
                                .source_frame_rate
                                .map(|rate| rate.as_rational().as_f64())
                                .filter(|value| value.is_finite() && *value > 0.0),
                        )
                    })
                    .unwrap_or((None, None, None));
                return Ok(ImportProbe {
                    duration,
                    width,
                    height,
                    fps,
                    has_audio: Some(probe.has_audio()),
                });
            }
            Err(error) => {
                tracing::warn!(
                    path = %path.display(),
                    error = %error,
                    "media probe failed during import, using extension defaults"
                );
            }
        }
    }

    let _ = path;
    Ok(ImportProbe {
        duration: default_duration_for_kind(kind),
        width: None,
        height: None,
        fps: None,
        has_audio: Some(matches!(kind, ClipType::Audio | ClipType::Video)),
    })
}

fn default_duration_for_kind(kind: ClipType) -> f64 {
    match kind {
        ClipType::Image | ClipType::Text | ClipType::Lottie => 5.0,
        ClipType::Video | ClipType::Audio | ClipType::Sequence => 0.0,
    }
}
