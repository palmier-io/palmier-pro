use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};

use tokio_util::sync::CancellationToken;

use crate::atomic::{
    CancelOnDrop, StageGuard, absolute_lexical, check_cancelled, copy_regular_file,
    lock_destination, remove_any, rename_exchange, rename_noreplace, sync_directory,
    unique_sibling,
};
use crate::filename::{safe_filename, unique_path, validate_filename};
use crate::{
    MEDIA_DIRECTORY_NAME, MediaManifest, MediaManifestEntry, MediaSource, MutationPermit,
    PackageCoordinator, ProjectError, Result,
};

#[derive(Clone, Debug)]
pub struct SourceResolver {
    manifest: MediaManifest,
    project_path: Option<PathBuf>,
}

impl SourceResolver {
    pub fn new(manifest: MediaManifest, project_path: Option<PathBuf>) -> Self {
        Self {
            manifest,
            project_path,
        }
    }

    pub fn manifest(&self) -> &MediaManifest {
        &self.manifest
    }

    pub fn entry(&self, asset_id: &str) -> Option<&MediaManifestEntry> {
        self.manifest
            .entries
            .iter()
            .find(|entry| entry.id == asset_id)
    }

    pub fn display_name(&self, asset_id: &str) -> &str {
        self.entry(asset_id)
            .map_or("Offline", |entry| entry.name.as_str())
    }

    pub fn expected_path(&self, asset_id: &str) -> Result<Option<PathBuf>> {
        self.entry(asset_id)
            .map(|entry| expected_source_path(&entry.source, self.project_path.as_deref()))
            .transpose()
            .map(Option::flatten)
    }

    pub fn expected_paths(&self) -> Result<Vec<(String, PathBuf)>> {
        let mut seen = HashSet::new();
        let mut paths = Vec::new();
        for entry in &self.manifest.entries {
            if !seen.insert(entry.id.clone()) {
                continue;
            }
            if let Some(path) = expected_source_path(&entry.source, self.project_path.as_deref())? {
                paths.push((entry.id.clone(), path));
            }
        }
        Ok(paths)
    }

    pub async fn resolve(&self, asset_id: &str) -> Result<Option<PathBuf>> {
        self.resolve_with_cancellation(asset_id, CancellationToken::new())
            .await
    }

    pub async fn resolve_with_cancellation(
        &self,
        asset_id: &str,
        cancellation: CancellationToken,
    ) -> Result<Option<PathBuf>> {
        let Some(path) = self.expected_path(asset_id)? else {
            return Ok(None);
        };
        tokio::select! {
            _ = cancellation.cancelled() => Err(ProjectError::Cancelled),
            result = tokio::fs::metadata(&path) => match result {
                Ok(_) => Ok(Some(path)),
                Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
                Err(error) => Err(ProjectError::io("resolve media source", &path, error)),
            },
        }
    }

    pub async fn missing_asset_ids(&self) -> Result<HashSet<String>> {
        self.missing_asset_ids_with_cancellation(CancellationToken::new())
            .await
    }

    pub async fn missing_asset_ids_with_cancellation(
        &self,
        cancellation: CancellationToken,
    ) -> Result<HashSet<String>> {
        let entries = self.manifest.entries.clone();
        let project_path = self.project_path.clone();
        let blocking_cancellation = cancellation.clone();
        let task = tokio::task::spawn_blocking(move || {
            let mut missing = HashSet::new();
            for entry in entries {
                check_cancelled(&blocking_cancellation)?;
                let path = expected_source_path(&entry.source, project_path.as_deref())?;
                if path.as_deref().is_none_or(|path| !path.exists()) {
                    missing.insert(entry.id);
                }
            }
            Ok(missing)
        });
        tokio::select! {
            _ = cancellation.cancelled() => Err(ProjectError::Cancelled),
            result = task => result
                .map_err(|error| ProjectError::Join(error.to_string()))?,
        }
    }
}

fn expected_source_path(
    source: &MediaSource,
    project_path: Option<&Path>,
) -> Result<Option<PathBuf>> {
    match source {
        MediaSource::External { absolute_path } => {
            let path = PathBuf::from(absolute_path);
            if !path.is_absolute() {
                return Err(ProjectError::RelativeExternalPath(path));
            }
            Ok(Some(path))
        }
        MediaSource::Project { relative_path } => {
            let Some(project_path) = project_path else {
                return Ok(None);
            };
            let relative = Path::new(relative_path);
            if relative.as_os_str().is_empty()
                || relative.is_absolute()
                || relative
                    .components()
                    .any(|component| !matches!(component, Component::Normal(_) | Component::CurDir))
            {
                return Err(ProjectError::InvalidRelativePath(relative.to_path_buf()));
            }
            Ok(Some(project_path.join(relative)))
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum InstallNamePolicy {
    #[default]
    Unique,
    Replace,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstalledMedia {
    pub path: PathBuf,
    pub filename: String,
    pub bytes: u64,
    pub cleanup_warning: Option<String>,
}

pub struct PreparedMedia {
    path: Option<PathBuf>,
    package_path: PathBuf,
    bytes: u64,
}

impl PreparedMedia {
    pub fn path(&self) -> &Path {
        self.path.as_deref().expect("live prepared media")
    }

    pub fn package_path(&self) -> &Path {
        &self.package_path
    }

    pub fn bytes(&self) -> u64 {
        self.bytes
    }

    fn take_path(&mut self) -> PathBuf {
        self.path.take().expect("live prepared media")
    }
}

impl Drop for PreparedMedia {
    fn drop(&mut self) {
        if let Some(path) = self.path.take() {
            remove_later(path);
        }
    }
}

#[derive(Clone)]
pub struct MediaInstaller {
    coordinator: PackageCoordinator,
}

struct InstallSourceRequest {
    package_path: PathBuf,
    source: PathBuf,
    preferred_name: String,
    policy: InstallNamePolicy,
    max_bytes: Option<u64>,
    consume_source: bool,
    cancellation: CancellationToken,
}

impl MediaInstaller {
    pub fn new(coordinator: PackageCoordinator) -> Self {
        Self { coordinator }
    }

    pub fn coordinator(&self) -> &PackageCoordinator {
        &self.coordinator
    }

    pub async fn prepare_media(
        &self,
        source: impl AsRef<Path>,
        package_path: impl AsRef<Path>,
        max_bytes: Option<u64>,
    ) -> Result<PreparedMedia> {
        self.prepare_media_with_cancellation(
            source,
            package_path,
            max_bytes,
            CancellationToken::new(),
        )
        .await
    }

    pub async fn prepare_media_with_cancellation(
        &self,
        source: impl AsRef<Path>,
        package_path: impl AsRef<Path>,
        max_bytes: Option<u64>,
        cancellation: CancellationToken,
    ) -> Result<PreparedMedia> {
        prepare_media_file(
            source.as_ref().to_path_buf(),
            package_path.as_ref().to_path_buf(),
            max_bytes,
            cancellation,
        )
        .await
    }

    pub async fn install_media_file(
        &self,
        package_path: impl AsRef<Path>,
        source: impl AsRef<Path>,
        preferred_name: &str,
        policy: InstallNamePolicy,
        max_bytes: Option<u64>,
    ) -> Result<InstalledMedia> {
        self.install_media_file_with_cancellation(
            package_path,
            source,
            preferred_name,
            policy,
            max_bytes,
            CancellationToken::new(),
        )
        .await
    }

    pub async fn install_media_file_with_cancellation(
        &self,
        package_path: impl AsRef<Path>,
        source: impl AsRef<Path>,
        preferred_name: &str,
        policy: InstallNamePolicy,
        max_bytes: Option<u64>,
        cancellation: CancellationToken,
    ) -> Result<InstalledMedia> {
        self.install_source(InstallSourceRequest {
            package_path: package_path.as_ref().to_path_buf(),
            source: source.as_ref().to_path_buf(),
            preferred_name: preferred_name.to_owned(),
            policy,
            max_bytes,
            consume_source: false,
            cancellation,
        })
        .await
    }

    pub async fn install_staged_media(
        &self,
        package_path: impl AsRef<Path>,
        staged_source: impl AsRef<Path>,
        preferred_name: &str,
        policy: InstallNamePolicy,
        max_bytes: Option<u64>,
    ) -> Result<InstalledMedia> {
        self.install_staged_media_with_cancellation(
            package_path,
            staged_source,
            preferred_name,
            policy,
            max_bytes,
            CancellationToken::new(),
        )
        .await
    }

    pub async fn install_staged_media_with_cancellation(
        &self,
        package_path: impl AsRef<Path>,
        staged_source: impl AsRef<Path>,
        preferred_name: &str,
        policy: InstallNamePolicy,
        max_bytes: Option<u64>,
        cancellation: CancellationToken,
    ) -> Result<InstalledMedia> {
        self.install_source(InstallSourceRequest {
            package_path: package_path.as_ref().to_path_buf(),
            source: staged_source.as_ref().to_path_buf(),
            preferred_name: preferred_name.to_owned(),
            policy,
            max_bytes,
            consume_source: true,
            cancellation,
        })
        .await
    }

    pub async fn install_prepared(
        &self,
        package_path: impl AsRef<Path>,
        prepared: PreparedMedia,
        preferred_name: &str,
        policy: InstallNamePolicy,
    ) -> Result<InstalledMedia> {
        self.install_prepared_with_cancellation(
            package_path,
            prepared,
            preferred_name,
            policy,
            CancellationToken::new(),
        )
        .await
    }

    pub async fn install_prepared_with_cancellation(
        &self,
        package_path: impl AsRef<Path>,
        prepared: PreparedMedia,
        preferred_name: &str,
        policy: InstallNamePolicy,
        cancellation: CancellationToken,
    ) -> Result<InstalledMedia> {
        let permit = self.coordinator.admit_mutation()?;
        run_prepared_install(
            permit,
            package_path.as_ref().to_path_buf(),
            prepared,
            preferred_name.to_owned(),
            policy,
            cancellation,
        )
        .await
    }

    async fn install_source(&self, request: InstallSourceRequest) -> Result<InstalledMedia> {
        let InstallSourceRequest {
            package_path,
            source,
            preferred_name,
            policy,
            max_bytes,
            consume_source,
            cancellation,
        } = request;
        if cancellation.is_cancelled() {
            if consume_source {
                let _ = remove_path(source).await;
            }
            return Err(ProjectError::Cancelled);
        }
        let permit = match self.coordinator.admit_mutation() {
            Ok(permit) => permit,
            Err(error) => {
                if consume_source {
                    let _ = remove_path(source).await;
                }
                return Err(error.into());
            }
        };
        let operation_cancellation = cancellation.child_token();
        let mut cancel_on_drop = CancelOnDrop::new(operation_cancellation.clone());
        let task = tokio::spawn(async move {
            let mut source_cleanup = consume_source.then(|| PathCleanup::new(source.clone()));
            let mut result = async {
                let prepared = prepare_media_file(
                    source.clone(),
                    package_path.clone(),
                    max_bytes,
                    operation_cancellation.clone(),
                )
                .await?;
                run_prepared_install_inner(
                    permit,
                    package_path,
                    prepared,
                    preferred_name,
                    policy,
                    operation_cancellation,
                )
                .await
            }
            .await;
            if consume_source {
                let cleanup = remove_path(source).await;
                if cleanup.is_ok()
                    && let Some(cleanup) = &mut source_cleanup
                {
                    cleanup.disarm();
                }
                if let (Ok(installed), Err(error)) = (&mut result, cleanup) {
                    installed.cleanup_warning = Some(match installed.cleanup_warning.take() {
                        Some(existing) => format!("{existing}. {error}"),
                        None => error.to_string(),
                    });
                }
            }
            result
        });
        let result = task
            .await
            .map_err(|error| ProjectError::Join(error.to_string()))?;
        cancel_on_drop.disarm();
        result
    }
}

async fn prepare_media_file(
    source: PathBuf,
    package_path: PathBuf,
    max_bytes: Option<u64>,
    cancellation: CancellationToken,
) -> Result<PreparedMedia> {
    if cancellation.is_cancelled() {
        return Err(ProjectError::Cancelled);
    }
    let operation_cancellation = cancellation.child_token();
    let mut cancel_on_drop = CancelOnDrop::new(operation_cancellation.clone());
    let task = tokio::task::spawn_blocking(move || {
        check_cancelled(&operation_cancellation)?;
        let package_path = absolute_lexical(&package_path)?;
        let prepared_path = unique_sibling(&package_path, "media")?;
        let mut guard = StageGuard::new(prepared_path.clone());
        let bytes = copy_regular_file(&source, &prepared_path, max_bytes, &operation_cancellation)?;
        check_cancelled(&operation_cancellation)?;
        guard.disarm();
        Ok(PreparedMedia {
            path: Some(prepared_path),
            package_path,
            bytes,
        })
    });
    let result = task
        .await
        .map_err(|error| ProjectError::Join(error.to_string()))?;
    cancel_on_drop.disarm();
    result
}

async fn run_prepared_install(
    permit: MutationPermit,
    package_path: PathBuf,
    prepared: PreparedMedia,
    preferred_name: String,
    policy: InstallNamePolicy,
    cancellation: CancellationToken,
) -> Result<InstalledMedia> {
    if cancellation.is_cancelled() {
        return Err(ProjectError::Cancelled);
    }
    let operation_cancellation = cancellation.child_token();
    let mut cancel_on_drop = CancelOnDrop::new(operation_cancellation.clone());
    let task = tokio::spawn(run_prepared_install_inner(
        permit,
        package_path,
        prepared,
        preferred_name,
        policy,
        operation_cancellation,
    ));
    let result = task
        .await
        .map_err(|error| ProjectError::Join(error.to_string()))?;
    cancel_on_drop.disarm();
    result
}

async fn run_prepared_install_inner(
    mut permit: MutationPermit,
    package_path: PathBuf,
    prepared: PreparedMedia,
    preferred_name: String,
    policy: InstallNamePolicy,
    cancellation: CancellationToken,
) -> Result<InstalledMedia> {
    permit.wait_until_ready().await?;
    check_cancelled(&cancellation)?;
    let package_path = absolute_path_async(package_path).await?;
    if package_path != prepared.package_path {
        return Err(ProjectError::InvalidRelativePath(package_path));
    }
    let _destination_guard = lock_destination(&package_path, &cancellation).await?;
    check_cancelled(&cancellation)?;
    let blocking_cancellation = cancellation.clone();
    tokio::task::spawn_blocking(move || {
        commit_prepared_media(
            prepared,
            &package_path,
            &preferred_name,
            policy,
            &blocking_cancellation,
        )
    })
    .await
    .map_err(|error| ProjectError::Join(error.to_string()))?
}

fn commit_prepared_media(
    mut prepared: PreparedMedia,
    package_path: &Path,
    preferred_name: &str,
    policy: InstallNamePolicy,
    cancellation: &CancellationToken,
) -> Result<InstalledMedia> {
    check_cancelled(cancellation)?;
    let package_metadata = fs::symlink_metadata(package_path)
        .map_err(|error| ProjectError::io("open project package", package_path, error))?;
    if !package_metadata.is_dir() {
        return Err(ProjectError::NotPackage(package_path.to_path_buf()));
    }
    let media_directory = package_path.join(MEDIA_DIRECTORY_NAME);
    match fs::symlink_metadata(&media_directory) {
        Ok(metadata) if metadata.is_dir() => {}
        Ok(_) => {
            return Err(ProjectError::io(
                "open project media directory",
                &media_directory,
                io::Error::new(io::ErrorKind::InvalidData, "media is not a directory"),
            ));
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            fs::create_dir(&media_directory).map_err(|error| {
                ProjectError::io("create project media directory", &media_directory, error)
            })?;
            sync_directory(package_path)?;
        }
        Err(error) => {
            return Err(ProjectError::io(
                "open project media directory",
                &media_directory,
                error,
            ));
        }
    }

    let safe_name = safe_filename(preferred_name, "media");
    validate_filename(&safe_name)?;
    let prepared_path = prepared.path().to_path_buf();
    let destination = match policy {
        InstallNamePolicy::Unique => {
            install_unique(&prepared_path, &media_directory, &safe_name, cancellation)?
        }
        InstallNamePolicy::Replace => {
            let destination = media_directory.join(&safe_name);
            check_cancelled(cancellation)?;
            match rename_noreplace(&prepared_path, &destination) {
                Ok(()) => {}
                Err(error)
                    if error.raw_os_error() == Some(libc::EEXIST)
                        || error.raw_os_error() == Some(libc::ENOTEMPTY) =>
                {
                    rename_exchange(&prepared_path, &destination).map_err(|error| {
                        ProjectError::io("replace project media", &destination, error)
                    })?;
                }
                Err(error) => {
                    return Err(ProjectError::io(
                        "install project media",
                        &destination,
                        error,
                    ));
                }
            }
            destination
        }
    };

    prepared.take_path();
    let mut warnings = Vec::new();
    if prepared_path.exists()
        && let Err(error) = remove_any(&prepared_path)
    {
        warnings.push(format!(
            "could not remove replaced media at {}: {error}",
            prepared_path.display()
        ));
    }
    if let Err(error) = sync_directory(&media_directory) {
        warnings.push(error.to_string());
    }
    let filename = destination
        .file_name()
        .expect("installed media has a filename")
        .to_string_lossy()
        .into_owned();
    Ok(InstalledMedia {
        path: destination,
        filename,
        bytes: prepared.bytes,
        cleanup_warning: if warnings.is_empty() {
            None
        } else {
            Some(warnings.join(". "))
        },
    })
}

fn install_unique(
    prepared: &Path,
    media_directory: &Path,
    preferred_name: &str,
    cancellation: &CancellationToken,
) -> Result<PathBuf> {
    loop {
        check_cancelled(cancellation)?;
        let destination = unique_path(media_directory, preferred_name)?;
        match rename_noreplace(prepared, &destination) {
            Ok(()) => return Ok(destination),
            Err(error) if error.raw_os_error() == Some(libc::EEXIST) => {}
            Err(error) => {
                return Err(ProjectError::io(
                    "install project media",
                    &destination,
                    error,
                ));
            }
        }
    }
}

async fn absolute_path_async(path: PathBuf) -> Result<PathBuf> {
    tokio::task::spawn_blocking(move || absolute_lexical(&path))
        .await
        .map_err(|error| ProjectError::Join(error.to_string()))?
}

struct PathCleanup {
    path: Option<PathBuf>,
}

impl PathCleanup {
    fn new(path: PathBuf) -> Self {
        Self { path: Some(path) }
    }

    fn disarm(&mut self) {
        self.path = None;
    }
}

impl Drop for PathCleanup {
    fn drop(&mut self) {
        if let Some(path) = self.path.take() {
            remove_later(path);
        }
    }
}

fn remove_later(path: PathBuf) {
    if let Ok(handle) = tokio::runtime::Handle::try_current() {
        handle.spawn_blocking(move || {
            let _ = remove_any(&path);
        });
    } else {
        let _ = std::thread::Builder::new()
            .name("palmier-stage-cleanup".to_owned())
            .spawn(move || {
                let _ = remove_any(&path);
            });
    }
}

async fn remove_path(path: PathBuf) -> Result<()> {
    let cleanup_path = path.clone();
    tokio::task::spawn_blocking(move || {
        remove_any(&cleanup_path)
            .map_err(|error| ProjectError::io("remove staged media", &cleanup_path, error))
    })
    .await
    .map_err(|error| ProjectError::Join(error.to_string()))?
}
