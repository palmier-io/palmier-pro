use std::fs;
use std::path::{Path, PathBuf};

use tokio_util::sync::CancellationToken;

use crate::atomic::{CancelOnDrop, check_cancelled};
use crate::{ClipType, ProjectError, Result};

pub type MediaKind = ClipType;

const VIDEO_EXTENSIONS: &[&str] = &["mov", "mp4", "m4v"];
const AUDIO_EXTENSIONS: &[&str] = &[
    "mp3", "wav", "aac", "m4a", "aiff", "aif", "aifc", "caf", "flac",
];
const IMAGE_EXTENSIONS: &[&str] = &["png", "jpg", "jpeg", "tiff", "heic", "webp"];
const LOTTIE_EXTENSIONS: &[&str] = &["json", "lottie"];

pub fn media_kind_for_extension(extension: &str) -> Option<MediaKind> {
    let extension = extension.trim_start_matches('.').to_ascii_lowercase();
    if VIDEO_EXTENSIONS.contains(&extension.as_str()) {
        Some(ClipType::Video)
    } else if AUDIO_EXTENSIONS.contains(&extension.as_str()) {
        Some(ClipType::Audio)
    } else if IMAGE_EXTENSIONS.contains(&extension.as_str()) {
        Some(ClipType::Image)
    } else if LOTTIE_EXTENSIONS.contains(&extension.as_str()) {
        Some(ClipType::Lottie)
    } else {
        None
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImportRoot {
    pub path: PathBuf,
    pub parent_folder_id: Option<String>,
}

impl ImportRoot {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            parent_folder_id: None,
        }
    }

    pub fn in_folder(path: impl Into<PathBuf>, parent_folder_id: impl Into<String>) -> Self {
        Self {
            path: path.into(),
            parent_folder_id: Some(parent_folder_id.into()),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ImportParent {
    ExistingFolder(Option<String>),
    PlannedFolder(usize),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImportFolder {
    pub name: String,
    pub parent: ImportParent,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImportFile {
    pub path: PathBuf,
    pub kind: MediaKind,
    pub name: String,
    pub parent: ImportParent,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImportWarning {
    pub path: PathBuf,
    pub message: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ImportPlan {
    pub folders: Vec<ImportFolder>,
    pub files: Vec<ImportFile>,
    pub rejected_unsupported_names: Vec<String>,
    pub warnings: Vec<ImportWarning>,
}

pub async fn plan_imports(roots: impl IntoIterator<Item = ImportRoot>) -> Result<ImportPlan> {
    plan_imports_with_cancellation(roots, CancellationToken::new()).await
}

pub async fn plan_imports_with_cancellation(
    roots: impl IntoIterator<Item = ImportRoot>,
    cancellation: CancellationToken,
) -> Result<ImportPlan> {
    if cancellation.is_cancelled() {
        return Err(ProjectError::Cancelled);
    }
    let roots = roots.into_iter().collect::<Vec<_>>();
    let operation_cancellation = cancellation.child_token();
    let mut cancel_on_drop = CancelOnDrop::new(operation_cancellation.clone());
    let task = tokio::task::spawn_blocking(move || scan_roots(roots, &operation_cancellation));
    let result = task
        .await
        .map_err(|error| ProjectError::Join(error.to_string()))?;
    cancel_on_drop.disarm();
    result
}

fn scan_roots(roots: Vec<ImportRoot>, cancellation: &CancellationToken) -> Result<ImportPlan> {
    let mut plan = ImportPlan::default();
    for root in roots {
        check_cancelled(cancellation)?;
        let parent = ImportParent::ExistingFolder(root.parent_folder_id);
        match fs::symlink_metadata(&root.path) {
            Ok(metadata) if metadata.is_dir() => {
                scan_folder(&root.path, parent, &mut plan, cancellation)?;
            }
            Ok(_) => {
                scan_file(&root.path, parent, true, &mut plan);
            }
            Err(error) => {
                plan.warnings.push(ImportWarning {
                    path: root.path,
                    message: error.to_string(),
                });
            }
        }
    }
    Ok(plan)
}

fn scan_folder(
    path: &Path,
    parent: ImportParent,
    plan: &mut ImportPlan,
    cancellation: &CancellationToken,
) -> Result<()> {
    check_cancelled(cancellation)?;
    let entries = match fs::read_dir(path) {
        Ok(entries) => entries,
        Err(error) => {
            plan.warnings.push(ImportWarning {
                path: path.to_path_buf(),
                message: error.to_string(),
            });
            return Ok(());
        }
    };

    let mut entries = entries
        .filter_map(|entry| match entry {
            Ok(entry) if !is_hidden(&entry.file_name().to_string_lossy()) => Some(entry.path()),
            Ok(_) => None,
            Err(error) => {
                plan.warnings.push(ImportWarning {
                    path: path.to_path_buf(),
                    message: error.to_string(),
                });
                None
            }
        })
        .collect::<Vec<_>>();
    entries.sort_by_key(|entry| sortable_name(entry));

    let folder_index = plan.folders.len();
    plan.folders.push(ImportFolder {
        name: display_stem(path),
        parent,
    });
    let child_parent = ImportParent::PlannedFolder(folder_index);
    for entry in entries {
        check_cancelled(cancellation)?;
        match fs::symlink_metadata(&entry) {
            Ok(metadata) if metadata.is_dir() => {
                scan_folder(&entry, child_parent.clone(), plan, cancellation)?;
            }
            Ok(_) => scan_file(&entry, child_parent.clone(), false, plan),
            Err(error) => plan.warnings.push(ImportWarning {
                path: entry,
                message: error.to_string(),
            }),
        }
    }
    Ok(())
}

fn scan_file(path: &Path, parent: ImportParent, is_root: bool, plan: &mut ImportPlan) {
    let kind = path
        .extension()
        .and_then(|extension| extension.to_str())
        .and_then(media_kind_for_extension);
    let Some(kind) = kind else {
        if is_root {
            plan.rejected_unsupported_names.push(display_name(path));
        }
        return;
    };
    plan.files.push(ImportFile {
        path: path.to_path_buf(),
        kind,
        name: path.file_stem().map_or_else(
            || display_name(path),
            |stem| stem.to_string_lossy().into_owned(),
        ),
        parent,
    });
}

fn is_hidden(name: &str) -> bool {
    name.starts_with('.')
}

fn display_name(path: &Path) -> String {
    path.file_name()
        .unwrap_or(path.as_os_str())
        .to_string_lossy()
        .into_owned()
}

fn display_stem(path: &Path) -> String {
    path.file_name()
        .unwrap_or(path.as_os_str())
        .to_string_lossy()
        .into_owned()
}

fn sortable_name(path: &Path) -> String {
    path.file_name()
        .map_or_else(String::new, |name| name.to_string_lossy().into_owned())
        .to_ascii_lowercase()
}
