use std::cmp::Ordering;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use palmier_core::SwiftDate;
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::atomic::{
    CancelOnDrop, StageGuard, absolute_lexical, check_cancelled, commit_staged_directory,
    lock_destination, unique_sibling, write_file,
};
use crate::{ProjectError, Result};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectEntry {
    pub id: Uuid,
    pub url: PathBuf,
    pub created_date: SwiftDate,
    pub last_opened_date: SwiftDate,
}

impl ProjectEntry {
    pub fn name(&self) -> String {
        self.url
            .file_stem()
            .unwrap_or(self.url.as_os_str())
            .to_string_lossy()
            .into_owned()
    }

    pub async fn is_accessible(&self) -> bool {
        tokio::fs::metadata(&self.url).await.is_ok()
    }
}

#[derive(Clone)]
pub struct RecentProjectRegistry {
    file_path: PathBuf,
    entries: Arc<Mutex<Vec<ProjectEntry>>>,
}

impl RecentProjectRegistry {
    pub async fn open(file_path: impl AsRef<Path>) -> Result<Self> {
        Self::open_with_cancellation(file_path, CancellationToken::new()).await
    }

    pub async fn open_with_cancellation(
        file_path: impl AsRef<Path>,
        cancellation: CancellationToken,
    ) -> Result<Self> {
        if cancellation.is_cancelled() {
            return Err(ProjectError::Cancelled);
        }
        let file_path = file_path.as_ref().to_path_buf();
        let blocking_cancellation = cancellation.clone();
        let task = tokio::task::spawn_blocking(move || {
            load_registry(&file_path, &blocking_cancellation).map(|entries| (file_path, entries))
        });
        let (file_path, entries) = tokio::select! {
            _ = cancellation.cancelled() => return Err(ProjectError::Cancelled),
            result = task => result
                .map_err(|error| ProjectError::Join(error.to_string()))??,
        };
        Ok(Self {
            file_path,
            entries: Arc::new(Mutex::new(entries)),
        })
    }

    pub async fn open_default() -> Result<Self> {
        Self::open(Self::default_file_path()).await
    }

    pub fn default_file_path() -> PathBuf {
        if let Some(state_home) = std::env::var_os("XDG_STATE_HOME") {
            return PathBuf::from(state_home)
                .join("palmier")
                .join("project-registry.json");
        }
        if let Some(home) = std::env::var_os("HOME") {
            return PathBuf::from(home)
                .join(".local")
                .join("state")
                .join("palmier")
                .join("project-registry.json");
        }
        PathBuf::from("project-registry.json")
    }

    pub fn file_path(&self) -> &Path {
        &self.file_path
    }

    pub async fn entries(&self) -> Vec<ProjectEntry> {
        self.entries.lock().await.clone()
    }

    pub async fn sorted_entries(&self) -> Vec<ProjectEntry> {
        let mut entries = self.entries().await;
        entries.sort_by(|left, right| {
            right
                .last_opened_date
                .partial_cmp(&left.last_opened_date)
                .unwrap_or(Ordering::Equal)
        });
        entries
    }

    pub async fn id_for(&self, url: impl AsRef<Path>) -> Result<Option<Uuid>> {
        let url = normalized_url(url.as_ref().to_path_buf()).await?;
        Ok(self
            .entries
            .lock()
            .await
            .iter()
            .find(|entry| entry.url == url)
            .map(|entry| entry.id))
    }

    pub async fn register(&self, url: impl AsRef<Path>) -> Result<ProjectEntry> {
        self.register_with_cancellation(url, CancellationToken::new())
            .await
    }

    pub async fn register_with_cancellation(
        &self,
        url: impl AsRef<Path>,
        cancellation: CancellationToken,
    ) -> Result<ProjectEntry> {
        let url = normalized_url(url.as_ref().to_path_buf()).await?;
        self.mutate(cancellation, move |entries| {
            let now = current_date();
            if let Some(entry) = entries.iter_mut().find(|entry| entry.url == url) {
                entry.last_opened_date = SwiftDate(now.0.max(entry.last_opened_date.0 + 0.000_001));
                entry.clone()
            } else {
                let entry = ProjectEntry {
                    id: Uuid::new_v4(),
                    url,
                    created_date: now,
                    last_opened_date: now,
                };
                entries.push(entry.clone());
                entry
            }
        })
        .await
    }

    pub async fn remove(&self, url: impl AsRef<Path>) -> Result<bool> {
        self.remove_with_cancellation(url, CancellationToken::new())
            .await
    }

    pub async fn remove_with_cancellation(
        &self,
        url: impl AsRef<Path>,
        cancellation: CancellationToken,
    ) -> Result<bool> {
        let url = normalized_url(url.as_ref().to_path_buf()).await?;
        self.mutate(cancellation, move |entries| {
            let previous_count = entries.len();
            entries.retain(|entry| entry.url != url);
            entries.len() != previous_count
        })
        .await
    }

    pub async fn update_url(
        &self,
        old_url: impl AsRef<Path>,
        new_url: impl AsRef<Path>,
    ) -> Result<bool> {
        self.update_url_with_cancellation(old_url, new_url, CancellationToken::new())
            .await
    }

    pub async fn update_url_with_cancellation(
        &self,
        old_url: impl AsRef<Path>,
        new_url: impl AsRef<Path>,
        cancellation: CancellationToken,
    ) -> Result<bool> {
        let old_url = normalized_url(old_url.as_ref().to_path_buf()).await?;
        let new_url = normalized_url(new_url.as_ref().to_path_buf()).await?;
        self.mutate(cancellation, move |entries| {
            let Some(entry) = entries.iter_mut().find(|entry| entry.url == old_url) else {
                return false;
            };
            entry.url = new_url;
            let now = current_date();
            entry.last_opened_date = SwiftDate(now.0.max(entry.last_opened_date.0 + 0.000_001));
            true
        })
        .await
    }

    async fn mutate<T, F>(&self, cancellation: CancellationToken, mutation: F) -> Result<T>
    where
        T: Send + 'static,
        F: FnOnce(&mut Vec<ProjectEntry>) -> T + Send + 'static,
    {
        if cancellation.is_cancelled() {
            return Err(ProjectError::Cancelled);
        }
        let operation_cancellation = cancellation.child_token();
        let mut cancel_on_drop = CancelOnDrop::new(operation_cancellation.clone());
        let entries = self.entries.clone();
        let file_path = self.file_path.clone();
        let task = tokio::spawn(async move {
            let mut current = entries.lock().await;
            check_cancelled(&operation_cancellation)?;
            let mut next = current.clone();
            let output = mutation(&mut next);
            let _destination_guard = lock_destination(&file_path, &operation_cancellation).await?;
            let blocking_cancellation = operation_cancellation.clone();
            let persisted_path = file_path.clone();
            tokio::task::spawn_blocking(move || {
                persist_registry(&persisted_path, &next, &blocking_cancellation).map(|()| next)
            })
            .await
            .map_err(|error| ProjectError::Join(error.to_string()))?
            .map(|persisted| {
                *current = persisted;
                output
            })
        });
        let result = task
            .await
            .map_err(|error| ProjectError::Join(error.to_string()))?;
        cancel_on_drop.disarm();
        result
    }
}

fn load_registry(file_path: &Path, cancellation: &CancellationToken) -> Result<Vec<ProjectEntry>> {
    check_cancelled(cancellation)?;
    let file_path = absolute_lexical(file_path)?;
    let bytes = match fs::read(&file_path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Ok(Vec::new());
        }
        Err(error) => {
            return Err(ProjectError::io("read project registry", &file_path, error));
        }
    };
    check_cancelled(cancellation)?;
    Ok(serde_json::from_slice(&bytes).unwrap_or_default())
}

fn persist_registry(
    file_path: &Path,
    entries: &[ProjectEntry],
    cancellation: &CancellationToken,
) -> Result<()> {
    check_cancelled(cancellation)?;
    let file_path = absolute_lexical(file_path)?;
    let parent = file_path
        .parent()
        .ok_or_else(|| ProjectError::InvalidRelativePath(file_path.clone()))?;
    fs::create_dir_all(parent)
        .map_err(|error| ProjectError::io("create registry directory", parent, error))?;
    let data = serde_json::to_vec_pretty(entries)
        .map_err(|error| ProjectError::json("project registry", error))?;
    let staging = unique_sibling(&file_path, "registry")?;
    let _stage_guard = StageGuard::new(staging.clone());
    write_file(&staging, &data, cancellation)?;
    check_cancelled(cancellation)?;
    let _ = commit_staged_directory(&staging, &file_path)?;
    Ok(())
}

async fn normalized_url(url: PathBuf) -> Result<PathBuf> {
    tokio::task::spawn_blocking(move || absolute_lexical(&url))
        .await
        .map_err(|error| ProjectError::Join(error.to_string()))?
}

fn current_date() -> SwiftDate {
    let unix_seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64();
    SwiftDate::from_unix_seconds(unix_seconds)
}
