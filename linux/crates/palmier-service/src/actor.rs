use std::path::PathBuf;
use std::sync::Arc;

use palmier_core::{EditorCommand, EditorSession};
use palmier_project::{ManifestState, OpenedProject, PackageCoordinator, ProjectSnapshot};
use tokio::sync::Mutex;
use uuid::Uuid;

use crate::error::{Result, ServiceError};
use crate::snapshot::{EditResult, OpenProjectSummary, PreviewResult, ProjectView};

pub(crate) struct ProjectActor {
    id: Uuid,
    inner: Mutex<ProjectState>,
    coordinator: PackageCoordinator,
}

pub(crate) struct ProjectState {
    session: EditorSession,
    path: Option<PathBuf>,
    dirty: bool,
    closed: bool,
}

impl ProjectActor {
    pub(crate) fn new_empty(id: Uuid) -> Result<Arc<Self>> {
        let mut timeline = palmier_core::Timeline::default();
        timeline.tracks = vec![
            palmier_core::Track::new(palmier_core::ClipType::Video),
            palmier_core::Track::new(palmier_core::ClipType::Audio),
        ];
        let project = palmier_core::ProjectFile::new(vec![timeline])
            .map_err(|error| {
                ServiceError::Mutation(palmier_core::MutationError::new(
                    palmier_core::MutationErrorCode::InvalidArgument,
                    error.to_string(),
                ))
            })?;
        let session = EditorSession::new(project)?;
        Ok(Self::from_parts(id, session, None, false))
    }

    pub(crate) fn from_opened(id: Uuid, opened: OpenedProject) -> Result<Arc<Self>> {
        let manifest = match opened.manifest {
            ManifestState::Valid(manifest) => manifest,
            ManifestState::Missing | ManifestState::Corrupt(_) => {
                palmier_core::MediaManifest::default()
            }
        };
        let session = EditorSession::with_manifest(opened.project, manifest)?;
        Ok(Self::from_parts(id, session, Some(opened.path), false))
    }

    fn from_parts(
        id: Uuid,
        session: EditorSession,
        path: Option<PathBuf>,
        dirty: bool,
    ) -> Arc<Self> {
        Arc::new(Self {
            id,
            inner: Mutex::new(ProjectState {
                session,
                path,
                dirty,
                closed: false,
            }),
            coordinator: PackageCoordinator::new(),
        })
    }

    pub(crate) async fn summary(&self) -> OpenProjectSummary {
        let state = self.inner.lock().await;
        state.summary(self.id)
    }

    pub(crate) async fn view(&self) -> ProjectView {
        let state = self.inner.lock().await;
        ProjectView {
            summary: state.summary(self.id),
            snapshot: state.session.snapshot(),
        }
    }

    pub(crate) async fn preview(
        &self,
        expected_revision: u64,
        command: EditorCommand,
    ) -> Result<PreviewResult> {
        let state = self.inner.lock().await;
        state.ensure_open(self.id)?;
        state.ensure_revision(self.id, expected_revision)?;
        let (receipt, snapshot) = state.session.preview(command)?;
        Ok(PreviewResult {
            project_id: self.id,
            expected_revision,
            receipt,
            snapshot,
        })
    }

    pub(crate) async fn commit(
        &self,
        expected_revision: u64,
        command: EditorCommand,
        include_snapshot: bool,
    ) -> Result<EditResult> {
        let mut permit = self.coordinator.admit_mutation()?;
        permit.wait_until_ready().await?;

        let mut state = self.inner.lock().await;
        state.ensure_open(self.id)?;
        state.ensure_revision(self.id, expected_revision)?;

        let receipt = state.session.execute(command)?;
        if receipt.changed() {
            state.dirty = true;
        }

        Ok(EditResult {
            project_id: self.id,
            revision: state.session.revision(),
            dirty: state.dirty,
            snapshot: include_snapshot.then(|| state.session.snapshot()),
            receipt,
        })
    }

    pub(crate) async fn begin_close(&self) {
        self.coordinator.begin_close().await;
        let mut state = self.inner.lock().await;
        state.closed = true;
    }

    pub(crate) async fn is_closed(&self) -> bool {
        self.inner.lock().await.closed
    }

    pub(crate) async fn path(&self) -> Option<PathBuf> {
        self.inner.lock().await.path.clone()
    }

    pub(crate) async fn take_save_snapshot(
        &self,
    ) -> Result<(Option<PathBuf>, ProjectSnapshot, u64)> {
        let state = self.inner.lock().await;
        state.ensure_open(self.id)?;
        let snapshot = ProjectSnapshot::new(
            state.session.project().clone(),
            state.session.media_manifest().clone(),
        );
        Ok((state.path.clone(), snapshot, state.session.revision()))
    }

    pub(crate) async fn mark_saved(
        &self,
        path: PathBuf,
        expected_revision: u64,
    ) -> Result<OpenProjectSummary> {
        let mut state = self.inner.lock().await;
        state.ensure_open(self.id)?;
        if state.session.revision() != expected_revision {
            return Err(ServiceError::RevisionMismatch {
                project_id: self.id,
                expected: expected_revision,
                actual: state.session.revision(),
            });
        }
        state.path = Some(path);
        state.dirty = false;
        Ok(state.summary(self.id))
    }

    pub(crate) async fn update_path_after_save_as(
        &self,
        path: PathBuf,
        expected_revision: u64,
    ) -> Result<OpenProjectSummary> {
        self.mark_saved(path, expected_revision).await
    }

    pub(crate) async fn with_session_mut<T, F>(&self, operation: F) -> Result<T>
    where
        F: FnOnce(&mut ProjectState) -> Result<T>,
    {
        let mut permit = self.coordinator.admit_mutation()?;
        permit.wait_until_ready().await?;
        let mut state = self.inner.lock().await;
        state.ensure_open(self.id)?;
        operation(&mut state)
    }
}

impl ProjectState {
    fn ensure_open(&self, project_id: Uuid) -> Result<()> {
        if self.closed {
            Err(ServiceError::ProjectClosed(project_id))
        } else {
            Ok(())
        }
    }

    fn ensure_revision(&self, project_id: Uuid, expected: u64) -> Result<()> {
        let actual = self.session.revision();
        if actual != expected {
            Err(ServiceError::RevisionMismatch {
                project_id,
                expected,
                actual,
            })
        } else {
            Ok(())
        }
    }

    fn summary(&self, project_id: Uuid) -> OpenProjectSummary {
        OpenProjectSummary {
            project_id,
            path: self.path.clone(),
            dirty: self.dirty,
            revision: self.session.revision(),
            undo_depth: self.session.undo_depth(),
            redo_depth: self.session.redo_depth(),
            active_timeline_id: self
                .session
                .project()
                .active_timeline_id()
                .map(str::to_owned),
            timeline_count: self.session.project().timelines.len(),
            media_entry_count: self.session.media_manifest().entries.len(),
        }
    }

    pub(crate) fn session(&self) -> &EditorSession {
        &self.session
    }

    pub(crate) fn session_mut(&mut self) -> &mut EditorSession {
        &mut self.session
    }

    pub(crate) fn mark_dirty(&mut self) {
        self.dirty = true;
    }
}

pub(crate) type SharedProjectActor = Arc<ProjectActor>;
