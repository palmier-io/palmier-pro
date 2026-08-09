use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub use palmier_core::{
    ClipType, MediaFolder, MediaManifest, MediaManifestEntry, MediaSource, ProjectFile,
};

pub const PROJECT_FILE_EXTENSION: &str = "palmier";
pub const PROJECT_FILENAME: &str = "project.json";
pub const MANIFEST_FILENAME: &str = "media.json";
pub const THUMBNAIL_FILENAME: &str = "thumbnail.jpg";
pub const MEDIA_DIRECTORY_NAME: &str = "media";
pub const CHAT_DIRECTORY_NAME: &str = "chat";

#[derive(Clone, Debug, PartialEq)]
pub enum ManifestState {
    Missing,
    Valid(MediaManifest),
    Corrupt(Vec<u8>),
}

impl ManifestState {
    pub fn manifest(&self) -> Option<&MediaManifest> {
        match self {
            Self::Valid(manifest) => Some(manifest),
            Self::Missing | Self::Corrupt(_) => None,
        }
    }

    pub fn is_unreadable(&self) -> bool {
        matches!(self, Self::Corrupt(_))
    }

    pub fn corrupt_bytes(&self) -> Option<&[u8]> {
        match self {
            Self::Corrupt(bytes) => Some(bytes),
            Self::Missing | Self::Valid(_) => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct OpenedProject {
    pub path: PathBuf,
    pub project: ProjectFile,
    pub manifest: ManifestState,
}

impl OpenedProject {
    pub fn snapshot(&self) -> ProjectSnapshot {
        let manifest = match &self.manifest {
            ManifestState::Valid(manifest) => ManifestWrite::Replace(manifest.clone()),
            ManifestState::Missing | ManifestState::Corrupt(_) => ManifestWrite::Preserve,
        };
        ProjectSnapshot {
            project: self.project.clone(),
            manifest,
            thumbnail: EntryUpdate::Preserve,
            chat_sessions: EntryUpdate::Preserve,
        }
    }

    pub fn package_path(&self) -> &Path {
        &self.path
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum ManifestWrite {
    Preserve,
    Replace(MediaManifest),
    Remove,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub enum EntryUpdate<T> {
    #[default]
    Preserve,
    Replace(T),
    Remove,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ProjectSnapshot {
    pub project: ProjectFile,
    pub manifest: ManifestWrite,
    pub thumbnail: EntryUpdate<Vec<u8>>,
    pub chat_sessions: EntryUpdate<BTreeMap<String, Vec<u8>>>,
}

impl ProjectSnapshot {
    pub fn new(project: ProjectFile, manifest: MediaManifest) -> Self {
        Self {
            project,
            manifest: ManifestWrite::Replace(manifest),
            thumbnail: EntryUpdate::Preserve,
            chat_sessions: EntryUpdate::Preserve,
        }
    }

    pub fn preserving_manifest(project: ProjectFile) -> Self {
        Self {
            project,
            manifest: ManifestWrite::Preserve,
            thumbnail: EntryUpdate::Preserve,
            chat_sessions: EntryUpdate::Preserve,
        }
    }
}
