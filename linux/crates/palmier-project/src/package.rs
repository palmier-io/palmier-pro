use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::{self, Read};
use std::path::{Path, PathBuf};

use tokio_util::sync::CancellationToken;

use crate::atomic::{
    CancelOnDrop, StageGuard, absolute_lexical, check_cancelled, commit_staged_directory,
    copy_tree, lock_destinations, remove_any, sync_directory, unique_sibling, write_file,
};
use crate::filename::validate_filename;
use crate::{
    CHAT_DIRECTORY_NAME, EntryUpdate, MANIFEST_FILENAME, MEDIA_DIRECTORY_NAME, ManifestState,
    ManifestWrite, MediaInstaller, MediaManifest, OpenedProject, PROJECT_FILE_EXTENSION,
    PROJECT_FILENAME, PackageCoordinator, ProjectError, ProjectFile, ProjectSnapshot, Result,
    THUMBNAIL_FILENAME,
};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SaveReport {
    pub replaced_existing: bool,
    pub cleanup_warning: Option<String>,
}

#[derive(Clone, Default)]
pub struct ProjectPackageStore {
    coordinator: PackageCoordinator,
}

impl ProjectPackageStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_coordinator(coordinator: PackageCoordinator) -> Self {
        Self { coordinator }
    }

    pub fn coordinator(&self) -> &PackageCoordinator {
        &self.coordinator
    }

    pub fn media_installer(&self) -> MediaInstaller {
        MediaInstaller::new(self.coordinator.clone())
    }

    pub async fn open(&self, path: impl AsRef<Path>) -> Result<OpenedProject> {
        open_package(path).await
    }

    pub async fn open_with_cancellation(
        &self,
        path: impl AsRef<Path>,
        cancellation: CancellationToken,
    ) -> Result<OpenedProject> {
        open_package_with_cancellation(path, cancellation).await
    }

    pub async fn save(
        &self,
        destination: impl AsRef<Path>,
        snapshot: ProjectSnapshot,
    ) -> Result<SaveReport> {
        self.save_with_cancellation(destination, snapshot, CancellationToken::new())
            .await
    }

    pub async fn save_with_cancellation(
        &self,
        destination: impl AsRef<Path>,
        snapshot: ProjectSnapshot,
        cancellation: CancellationToken,
    ) -> Result<SaveReport> {
        self.run_save(
            SaveSource::DestinationIfPresent,
            destination.as_ref().to_path_buf(),
            snapshot,
            cancellation,
        )
        .await
    }

    pub async fn save_as(
        &self,
        source: impl AsRef<Path>,
        destination: impl AsRef<Path>,
        snapshot: ProjectSnapshot,
    ) -> Result<SaveReport> {
        self.save_as_with_cancellation(source, destination, snapshot, CancellationToken::new())
            .await
    }

    pub async fn save_as_with_cancellation(
        &self,
        source: impl AsRef<Path>,
        destination: impl AsRef<Path>,
        snapshot: ProjectSnapshot,
        cancellation: CancellationToken,
    ) -> Result<SaveReport> {
        self.run_save(
            SaveSource::Explicit(source.as_ref().to_path_buf()),
            destination.as_ref().to_path_buf(),
            snapshot,
            cancellation,
        )
        .await
    }

    async fn run_save(
        &self,
        source: SaveSource,
        destination: PathBuf,
        snapshot: ProjectSnapshot,
        cancellation: CancellationToken,
    ) -> Result<SaveReport> {
        if cancellation.is_cancelled() {
            return Err(ProjectError::Cancelled);
        }

        let operation_cancellation = cancellation.child_token();
        let mut cancel_on_drop = CancelOnDrop::new(operation_cancellation.clone());
        let save_permit = self.coordinator.start_save();
        let mut lock_paths = vec![destination.clone()];
        if let SaveSource::Explicit(source) = &source {
            lock_paths.push(source.clone());
        }
        let task = tokio::spawn(async move {
            let result = async {
                let _package_guards =
                    lock_destinations(&lock_paths, &operation_cancellation).await?;
                check_cancelled(&operation_cancellation)?;
                let blocking_cancellation = operation_cancellation.clone();
                tokio::task::spawn_blocking(move || {
                    save_package_sync(source, &destination, snapshot, &blocking_cancellation)
                })
                .await
                .map_err(|error| ProjectError::Join(error.to_string()))?
            }
            .await;
            save_permit.finish(result.is_ok());
            result
        });

        let result = task
            .await
            .map_err(|error| ProjectError::Join(error.to_string()))?;
        cancel_on_drop.disarm();
        result
    }
}

enum SaveSource {
    DestinationIfPresent,
    Explicit(PathBuf),
}

pub fn is_project_package_path(path: impl AsRef<Path>) -> bool {
    path.as_ref()
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case(PROJECT_FILE_EXTENSION))
}

pub async fn open_package(path: impl AsRef<Path>) -> Result<OpenedProject> {
    open_package_with_cancellation(path, CancellationToken::new()).await
}

pub async fn open_package_with_cancellation(
    path: impl AsRef<Path>,
    cancellation: CancellationToken,
) -> Result<OpenedProject> {
    if cancellation.is_cancelled() {
        return Err(ProjectError::Cancelled);
    }
    let path = path.as_ref().to_path_buf();
    let operation_cancellation = cancellation.child_token();
    let mut cancel_on_drop = CancelOnDrop::new(operation_cancellation.clone());
    let task = tokio::spawn(async move {
        let _package_guard =
            crate::atomic::lock_destination(&path, &operation_cancellation).await?;
        let blocking_cancellation = operation_cancellation.clone();
        tokio::task::spawn_blocking(move || open_package_sync(&path, &blocking_cancellation))
            .await
            .map_err(|error| ProjectError::Join(error.to_string()))?
    });
    let result = task
        .await
        .map_err(|error| ProjectError::Join(error.to_string()))?;
    cancel_on_drop.disarm();
    result
}

pub async fn save_package(
    destination: impl AsRef<Path>,
    snapshot: ProjectSnapshot,
) -> Result<SaveReport> {
    ProjectPackageStore::new().save(destination, snapshot).await
}

pub async fn save_package_with_cancellation(
    destination: impl AsRef<Path>,
    snapshot: ProjectSnapshot,
    cancellation: CancellationToken,
) -> Result<SaveReport> {
    ProjectPackageStore::new()
        .save_with_cancellation(destination, snapshot, cancellation)
        .await
}

pub async fn save_package_as(
    source: impl AsRef<Path>,
    destination: impl AsRef<Path>,
    snapshot: ProjectSnapshot,
) -> Result<SaveReport> {
    ProjectPackageStore::new()
        .save_as(source, destination, snapshot)
        .await
}

pub async fn save_package_as_with_cancellation(
    source: impl AsRef<Path>,
    destination: impl AsRef<Path>,
    snapshot: ProjectSnapshot,
    cancellation: CancellationToken,
) -> Result<SaveReport> {
    ProjectPackageStore::new()
        .save_as_with_cancellation(source, destination, snapshot, cancellation)
        .await
}

fn open_package_sync(
    package_path: &Path,
    cancellation: &CancellationToken,
) -> Result<OpenedProject> {
    check_cancelled(cancellation)?;
    let package_path = absolute_lexical(package_path)?;
    let metadata = fs::symlink_metadata(&package_path)
        .map_err(|error| ProjectError::io("open project package", &package_path, error))?;
    if !metadata.is_dir() {
        return Err(ProjectError::NotPackage(package_path));
    }

    let project_path = package_path.join(PROJECT_FILENAME);
    let project_bytes = read_file(&project_path, cancellation).map_err(|error| match error {
        ProjectError::Io { source, .. } if source.kind() == io::ErrorKind::NotFound => {
            ProjectError::io(
                "read required project.json",
                &project_path,
                io::Error::new(io::ErrorKind::InvalidData, "project.json is missing"),
            )
        }
        error => error,
    })?;
    let project = ProjectFile::decode_json(&project_bytes).map_err(ProjectError::InvalidProject)?;
    validate_project(&project)?;

    let manifest_path = package_path.join(MANIFEST_FILENAME);
    let manifest = match read_file(&manifest_path, cancellation) {
        Ok(bytes) => match serde_json::from_slice::<MediaManifest>(&bytes) {
            Ok(manifest) => ManifestState::Valid(manifest),
            Err(_) => ManifestState::Corrupt(bytes),
        },
        Err(ProjectError::Io { source, .. }) if source.kind() == io::ErrorKind::NotFound => {
            ManifestState::Missing
        }
        Err(error) => return Err(error),
    };

    Ok(OpenedProject {
        path: package_path,
        project,
        manifest,
    })
}

fn save_package_sync(
    source_mode: SaveSource,
    destination: &Path,
    snapshot: ProjectSnapshot,
    cancellation: &CancellationToken,
) -> Result<SaveReport> {
    check_cancelled(cancellation)?;
    validate_project(&snapshot.project)?;
    validate_chat_update(&snapshot.chat_sessions)?;

    let destination = absolute_lexical(destination)?;
    let parent = destination
        .parent()
        .ok_or_else(|| ProjectError::InvalidRelativePath(destination.clone()))?;
    fs::create_dir_all(parent)
        .map_err(|error| ProjectError::io("create package parent", parent, error))?;

    let destination_exists = match fs::symlink_metadata(&destination) {
        Ok(metadata) if metadata.is_dir() => true,
        Ok(_) => return Err(ProjectError::NotPackage(destination)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => false,
        Err(error) => {
            return Err(ProjectError::io(
                "inspect destination package",
                &destination,
                error,
            ));
        }
    };

    let source = match source_mode {
        SaveSource::DestinationIfPresent => {
            if destination_exists {
                Some(destination.clone())
            } else {
                None
            }
        }
        SaveSource::Explicit(source) => {
            let source = absolute_lexical(&source)?;
            let metadata = fs::symlink_metadata(&source).map_err(|error| {
                if error.kind() == io::ErrorKind::NotFound {
                    ProjectError::MissingSourcePackage(source.clone())
                } else {
                    ProjectError::io("open source package", &source, error)
                }
            })?;
            if !metadata.is_dir() {
                return Err(ProjectError::NotPackage(source));
            }
            Some(source)
        }
    };

    if let Some(source) = &source {
        let resolved_source = fs::canonicalize(source)
            .map_err(|error| ProjectError::io("resolve source package", source, error))?;
        let resolved_parent = fs::canonicalize(parent)
            .map_err(|error| ProjectError::io("resolve destination parent", parent, error))?;
        let resolved_destination = resolved_parent.join(
            destination
                .file_name()
                .ok_or_else(|| ProjectError::InvalidRelativePath(destination.clone()))?,
        );
        if resolved_destination != resolved_source
            && resolved_destination.starts_with(&resolved_source)
        {
            return Err(ProjectError::DestinationInsideSource);
        }
    }

    let staging = unique_sibling(&destination, "save")?;
    let mut staging_guard = StageGuard::new(staging.clone());
    if let Some(source) = &source {
        copy_tree(source, &staging, cancellation)?;
    } else {
        fs::create_dir(&staging).map_err(|error| {
            ProjectError::io("create package staging directory", &staging, error)
        })?;
    }

    let project_data = serde_json::to_vec_pretty(&snapshot.project)
        .map_err(|error| ProjectError::json("project.json", error))?;
    write_file(&staging.join(PROJECT_FILENAME), &project_data, cancellation)?;
    apply_manifest(&staging, snapshot.manifest, cancellation)?;
    apply_file_update(
        &staging.join(THUMBNAIL_FILENAME),
        snapshot.thumbnail,
        cancellation,
    )?;
    apply_chat_update(
        &staging.join(CHAT_DIRECTORY_NAME),
        snapshot.chat_sessions,
        cancellation,
    )?;
    ensure_media_directory(&staging)?;
    sync_directory(&staging)?;
    check_cancelled(cancellation)?;

    let commit = commit_staged_directory(&staging, &destination)?;
    staging_guard.disarm();
    Ok(SaveReport {
        replaced_existing: commit.replaced_existing,
        cleanup_warning: commit.cleanup_warning,
    })
}

fn validate_project(project: &ProjectFile) -> Result<()> {
    if project.timelines.is_empty() {
        Err(ProjectError::EmptyProject)
    } else {
        Ok(())
    }
}

fn apply_manifest(
    staging: &Path,
    update: ManifestWrite,
    cancellation: &CancellationToken,
) -> Result<()> {
    let path = staging.join(MANIFEST_FILENAME);
    match update {
        ManifestWrite::Preserve => Ok(()),
        ManifestWrite::Replace(manifest) => {
            let data = serde_json::to_vec_pretty(&manifest)
                .map_err(|error| ProjectError::json("media.json", error))?;
            write_file(&path, &data, cancellation)
        }
        ManifestWrite::Remove => {
            remove_any(&path).map_err(|error| ProjectError::io("remove media.json", &path, error))
        }
    }
}

fn apply_file_update(
    path: &Path,
    update: EntryUpdate<Vec<u8>>,
    cancellation: &CancellationToken,
) -> Result<()> {
    match update {
        EntryUpdate::Preserve => Ok(()),
        EntryUpdate::Replace(bytes) => write_file(path, &bytes, cancellation),
        EntryUpdate::Remove => {
            remove_any(path).map_err(|error| ProjectError::io("remove package entry", path, error))
        }
    }
}

fn validate_chat_update(update: &EntryUpdate<BTreeMap<String, Vec<u8>>>) -> Result<()> {
    if let EntryUpdate::Replace(sessions) = update {
        for name in sessions.keys() {
            validate_filename(name)?;
        }
    }
    Ok(())
}

fn apply_chat_update(
    path: &Path,
    update: EntryUpdate<BTreeMap<String, Vec<u8>>>,
    cancellation: &CancellationToken,
) -> Result<()> {
    match update {
        EntryUpdate::Preserve => Ok(()),
        EntryUpdate::Remove => {
            remove_any(path).map_err(|error| ProjectError::io("remove chat directory", path, error))
        }
        EntryUpdate::Replace(sessions) => {
            remove_any(path)
                .map_err(|error| ProjectError::io("replace chat directory", path, error))?;
            fs::create_dir(path)
                .map_err(|error| ProjectError::io("create chat directory", path, error))?;
            for (name, data) in sessions {
                check_cancelled(cancellation)?;
                write_file(&path.join(name), &data, cancellation)?;
            }
            sync_directory(path)
        }
    }
}

fn ensure_media_directory(staging: &Path) -> Result<()> {
    let media = staging.join(MEDIA_DIRECTORY_NAME);
    match fs::symlink_metadata(&media) {
        Ok(metadata) if metadata.is_dir() => Ok(()),
        Ok(_) => Err(ProjectError::io(
            "create media directory",
            &media,
            io::Error::new(
                io::ErrorKind::AlreadyExists,
                "media exists and is not a directory",
            ),
        )),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            fs::create_dir(&media)
                .map_err(|error| ProjectError::io("create media directory", &media, error))?;
            sync_directory(&media)
        }
        Err(error) => Err(ProjectError::io("inspect media directory", &media, error)),
    }
}

fn read_file(path: &Path, cancellation: &CancellationToken) -> Result<Vec<u8>> {
    check_cancelled(cancellation)?;
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| ProjectError::io("read file metadata", path, error))?;
    if !metadata.is_file() {
        return Err(ProjectError::io(
            "read file",
            path,
            io::Error::new(
                io::ErrorKind::InvalidData,
                "package entry is not a regular file",
            ),
        ));
    }
    let mut file = File::open(path).map_err(|error| ProjectError::io("read file", path, error))?;
    let mut bytes = Vec::new();
    let mut buffer = vec![0_u8; 1024 * 1024];
    loop {
        check_cancelled(cancellation)?;
        let count = file
            .read(&mut buffer)
            .map_err(|error| ProjectError::io("read file", path, error))?;
        if count == 0 {
            break;
        }
        bytes.extend_from_slice(&buffer[..count]);
    }
    Ok(bytes)
}
