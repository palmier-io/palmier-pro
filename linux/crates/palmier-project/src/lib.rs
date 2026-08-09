mod atomic;
mod coordinator;
mod error;
mod filename;
mod import;
mod media;
mod model;
mod package;
mod registry;

pub use coordinator::{CoordinatorError, MutationPermit, PackageCoordinator, SavePermit};
pub use error::{ProjectError, Result};
pub use filename::{safe_filename, unique_filename, unique_path, validate_filename};
pub use import::{
    ImportFile, ImportFolder, ImportParent, ImportPlan, ImportRoot, ImportWarning, MediaKind,
    media_kind_for_extension, plan_imports, plan_imports_with_cancellation,
};
pub use media::{InstallNamePolicy, InstalledMedia, MediaInstaller, PreparedMedia, SourceResolver};
pub use model::{
    CHAT_DIRECTORY_NAME, ClipType, EntryUpdate, MANIFEST_FILENAME, MEDIA_DIRECTORY_NAME,
    ManifestState, ManifestWrite, MediaFolder, MediaManifest, MediaManifestEntry, MediaSource,
    OpenedProject, PROJECT_FILE_EXTENSION, PROJECT_FILENAME, ProjectFile, ProjectSnapshot,
    THUMBNAIL_FILENAME,
};
pub use package::{
    ProjectPackageStore, SaveReport, is_project_package_path, open_package,
    open_package_with_cancellation, save_package, save_package_as,
    save_package_as_with_cancellation, save_package_with_cancellation,
};
pub use registry::{ProjectEntry, RecentProjectRegistry};
pub use tokio_util::sync::CancellationToken;

pub use palmier_core as core;
