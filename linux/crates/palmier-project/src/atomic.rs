use std::collections::HashMap;
use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, Weak};

use tokio::sync::{Mutex as AsyncMutex, OwnedMutexGuard};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::{ProjectError, Result};

const COPY_BUFFER_SIZE: usize = 1024 * 1024;

type LockMap = HashMap<PathBuf, Weak<AsyncMutex<()>>>;

static DESTINATION_LOCKS: OnceLock<Mutex<LockMap>> = OnceLock::new();

pub(crate) struct CancelOnDrop {
    cancellation: CancellationToken,
    armed: bool,
}

impl CancelOnDrop {
    pub fn new(cancellation: CancellationToken) -> Self {
        Self {
            cancellation,
            armed: true,
        }
    }

    pub fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        if self.armed {
            self.cancellation.cancel();
        }
    }
}

pub(crate) struct AtomicCommit {
    pub replaced_existing: bool,
    pub cleanup_warning: Option<String>,
}

pub(crate) struct StageGuard {
    path: Option<PathBuf>,
}

impl StageGuard {
    pub fn new(path: PathBuf) -> Self {
        Self { path: Some(path) }
    }

    pub fn disarm(&mut self) {
        self.path = None;
    }
}

impl Drop for StageGuard {
    fn drop(&mut self) {
        if let Some(path) = self.path.take() {
            let _ = remove_any(&path);
        }
    }
}

pub(crate) async fn lock_destination(
    path: &Path,
    cancellation: &CancellationToken,
) -> Result<OwnedMutexGuard<()>> {
    let mut guards = lock_destinations(&[path.to_path_buf()], cancellation).await?;
    Ok(guards.pop().expect("one destination lock"))
}

pub(crate) async fn lock_destinations(
    paths: &[PathBuf],
    cancellation: &CancellationToken,
) -> Result<Vec<OwnedMutexGuard<()>>> {
    let requested = paths.to_vec();
    let key_task = tokio::task::spawn_blocking(move || {
        requested
            .iter()
            .map(|path| destination_key(path))
            .collect::<Result<Vec<_>>>()
    });
    let mut keys = tokio::select! {
        _ = cancellation.cancelled() => return Err(ProjectError::Cancelled),
        result = key_task => result
            .map_err(|error| ProjectError::Join(error.to_string()))??,
    };
    keys.sort();
    keys.dedup();

    let locks = {
        let table = DESTINATION_LOCKS.get_or_init(|| Mutex::new(HashMap::new()));
        let mut table = table
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        table.retain(|_, lock| lock.strong_count() > 0);
        keys.into_iter()
            .map(|key| {
                if let Some(lock) = table.get(&key).and_then(Weak::upgrade) {
                    lock
                } else {
                    let lock = Arc::new(AsyncMutex::new(()));
                    table.insert(key, Arc::downgrade(&lock));
                    lock
                }
            })
            .collect::<Vec<_>>()
    };

    let mut guards = Vec::with_capacity(locks.len());
    for lock in locks {
        let guard = tokio::select! {
            _ = cancellation.cancelled() => return Err(ProjectError::Cancelled),
            guard = lock.lock_owned() => guard,
        };
        guards.push(guard);
    }
    Ok(guards)
}

pub(crate) fn write_file(
    path: &Path,
    bytes: &[u8],
    cancellation: &CancellationToken,
) -> Result<()> {
    check_cancelled(cancellation)?;
    remove_any(path).map_err(|error| ProjectError::io("replace file", path, error))?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|error| ProjectError::io("create file", path, error))?;
    let result = (|| {
        for chunk in bytes.chunks(COPY_BUFFER_SIZE) {
            check_cancelled(cancellation)?;
            file.write_all(chunk)
                .map_err(|error| ProjectError::io("write file", path, error))?;
        }
        file.sync_all()
            .map_err(|error| ProjectError::io("sync file", path, error))
    })();
    if result.is_err() {
        let _ = fs::remove_file(path);
    }
    result
}

fn destination_key(path: &Path) -> Result<PathBuf> {
    let absolute = absolute_lexical(path)?;
    let name = absolute
        .file_name()
        .ok_or_else(|| ProjectError::InvalidRelativePath(absolute.clone()))?;
    let parent = absolute.parent().unwrap_or_else(|| Path::new("/"));
    let resolved_parent = fs::canonicalize(parent).unwrap_or_else(|_| normalize_lexical(parent));
    Ok(resolved_parent.join(name))
}

pub(crate) fn absolute_lexical(path: &Path) -> Result<PathBuf> {
    if path.is_absolute() {
        return Ok(normalize_lexical(path));
    }
    let current = std::env::current_dir()
        .map_err(|error| ProjectError::io("read current directory", path, error))?;
    Ok(normalize_lexical(&current.join(path)))
}

pub(crate) fn normalize_lexical(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Prefix(prefix) => normalized.push(prefix.as_os_str()),
            Component::RootDir => normalized.push(Path::new("/")),
            Component::CurDir => {}
            Component::ParentDir => {
                if normalized.file_name().is_some() {
                    normalized.pop();
                }
            }
            Component::Normal(part) => normalized.push(part),
        }
    }
    normalized
}

pub(crate) fn unique_sibling(destination: &Path, purpose: &str) -> Result<PathBuf> {
    let parent = destination
        .parent()
        .ok_or_else(|| ProjectError::InvalidRelativePath(destination.to_path_buf()))?;
    let destination_name = destination
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("project");
    Ok(parent.join(format!(
        ".{destination_name}.{purpose}-{}.partial",
        Uuid::new_v4()
    )))
}

pub(crate) fn check_cancelled(cancellation: &CancellationToken) -> Result<()> {
    if cancellation.is_cancelled() {
        Err(ProjectError::Cancelled)
    } else {
        Ok(())
    }
}

pub(crate) fn copy_tree(
    source: &Path,
    destination: &Path,
    cancellation: &CancellationToken,
) -> Result<()> {
    check_cancelled(cancellation)?;
    let metadata = fs::symlink_metadata(source)
        .map_err(|error| ProjectError::io("read metadata", source, error))?;
    if !metadata.is_dir() {
        return Err(ProjectError::NotPackage(source.to_path_buf()));
    }
    fs::create_dir(destination)
        .map_err(|error| ProjectError::io("create staging directory", destination, error))?;

    let result = copy_directory_contents(
        source,
        destination,
        metadata.permissions().mode(),
        cancellation,
    );
    if result.is_err() {
        let _ = remove_any(destination);
    }
    result
}

fn copy_directory_contents(
    source: &Path,
    destination: &Path,
    mode: u32,
    cancellation: &CancellationToken,
) -> Result<()> {
    let entries =
        fs::read_dir(source).map_err(|error| ProjectError::io("read directory", source, error))?;
    for entry in entries {
        check_cancelled(cancellation)?;
        let entry =
            entry.map_err(|error| ProjectError::io("read directory entry", source, error))?;
        let source_path = entry.path();
        let destination_path = destination.join(entry.file_name());
        let metadata = fs::symlink_metadata(&source_path)
            .map_err(|error| ProjectError::io("read metadata", &source_path, error))?;
        let file_type = metadata.file_type();

        if file_type.is_dir() {
            fs::create_dir(&destination_path)
                .map_err(|error| ProjectError::io("create directory", &destination_path, error))?;
            copy_directory_contents(
                &source_path,
                &destination_path,
                metadata.permissions().mode(),
                cancellation,
            )?;
        } else if file_type.is_file() {
            copy_regular_file(&source_path, &destination_path, None, cancellation)?;
        } else if file_type.is_symlink() {
            let target = fs::read_link(&source_path)
                .map_err(|error| ProjectError::io("read symbolic link", &source_path, error))?;
            symlink(target, &destination_path).map_err(|error| {
                ProjectError::io("copy symbolic link", &destination_path, error)
            })?;
        } else {
            return Err(ProjectError::io(
                "copy unsupported package entry",
                &source_path,
                io::Error::new(
                    io::ErrorKind::Unsupported,
                    "only files, directories, and symbolic links are supported",
                ),
            ));
        }
    }

    fs::set_permissions(destination, fs::Permissions::from_mode(mode))
        .map_err(|error| ProjectError::io("set directory permissions", destination, error))?;
    sync_directory(destination)
}

pub(crate) fn copy_regular_file(
    source: &Path,
    destination: &Path,
    max_bytes: Option<u64>,
    cancellation: &CancellationToken,
) -> Result<u64> {
    check_cancelled(cancellation)?;
    let source_file =
        File::open(source).map_err(|error| ProjectError::io("open source file", source, error))?;
    let metadata = source_file
        .metadata()
        .map_err(|error| ProjectError::io("read source metadata", source, error))?;
    if let Some(max_bytes) = max_bytes
        && metadata.len() > max_bytes
    {
        return Err(ProjectError::FileTooLarge {
            size: metadata.len(),
            max_bytes,
        });
    }

    let destination_file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(destination)
        .map_err(|error| ProjectError::io("create destination file", destination, error))?;
    let result = copy_file_contents(
        source_file,
        destination_file,
        source,
        destination,
        metadata.permissions().mode(),
        max_bytes,
        cancellation,
    );
    if result.is_err() {
        let _ = fs::remove_file(destination);
    }
    result
}

fn copy_file_contents(
    source_file: File,
    destination_file: File,
    source_path: &Path,
    destination_path: &Path,
    mode: u32,
    max_bytes: Option<u64>,
    cancellation: &CancellationToken,
) -> Result<u64> {
    let mut reader = BufReader::with_capacity(COPY_BUFFER_SIZE, source_file);
    let mut writer = BufWriter::with_capacity(COPY_BUFFER_SIZE, destination_file);
    let mut buffer = vec![0_u8; COPY_BUFFER_SIZE];
    let mut written = 0_u64;

    loop {
        check_cancelled(cancellation)?;
        let count = reader
            .read(&mut buffer)
            .map_err(|error| ProjectError::io("read source file", source_path, error))?;
        if count == 0 {
            break;
        }
        written = written
            .checked_add(count as u64)
            .ok_or(ProjectError::FileTooLarge {
                size: u64::MAX,
                max_bytes: max_bytes.unwrap_or(u64::MAX),
            })?;
        if let Some(max_bytes) = max_bytes
            && written > max_bytes
        {
            return Err(ProjectError::FileTooLarge {
                size: written,
                max_bytes,
            });
        }
        writer
            .write_all(&buffer[..count])
            .map_err(|error| ProjectError::io("write destination file", destination_path, error))?;
    }

    writer
        .flush()
        .map_err(|error| ProjectError::io("flush destination file", destination_path, error))?;
    let destination_file = writer.into_inner().map_err(|error| {
        ProjectError::io(
            "flush destination file",
            destination_path,
            error.into_error(),
        )
    })?;
    destination_file
        .set_permissions(fs::Permissions::from_mode(mode))
        .map_err(|error| {
            ProjectError::io("set destination permissions", destination_path, error)
        })?;
    destination_file
        .sync_all()
        .map_err(|error| ProjectError::io("sync destination file", destination_path, error))?;
    Ok(written)
}

pub(crate) fn sync_directory(path: &Path) -> Result<()> {
    File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| ProjectError::io("sync directory", path, error))
}

pub(crate) fn remove_any(path: &Path) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_dir() => fs::remove_dir_all(path),
        Ok(_) => fs::remove_file(path),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

pub(crate) fn commit_staged_directory(staging: &Path, destination: &Path) -> Result<AtomicCommit> {
    let replaced_existing = match rename_noreplace(staging, destination) {
        Ok(()) => false,
        Err(error)
            if error.raw_os_error() == Some(libc::EEXIST)
                || error.raw_os_error() == Some(libc::ENOTEMPTY) =>
        {
            rename_exchange(staging, destination).map_err(|source| {
                ProjectError::AtomicExchange {
                    path: destination.to_path_buf(),
                    source,
                }
            })?;
            true
        }
        Err(error) => {
            return Err(ProjectError::io(
                "install project package",
                destination,
                error,
            ));
        }
    };

    let mut warnings = Vec::new();
    if replaced_existing && let Err(error) = remove_any(staging) {
        warnings.push(format!(
            "could not remove replaced package at {}: {error}",
            staging.display()
        ));
    }
    if let Some(parent) = destination.parent()
        && let Err(error) = sync_directory(parent)
    {
        warnings.push(error.to_string());
    }

    Ok(AtomicCommit {
        replaced_existing,
        cleanup_warning: if warnings.is_empty() {
            None
        } else {
            Some(warnings.join(". "))
        },
    })
}

pub(crate) fn rename_exchange(source: &Path, destination: &Path) -> io::Result<()> {
    renameat2(source, destination, libc::RENAME_EXCHANGE)
}

pub(crate) fn rename_noreplace(source: &Path, destination: &Path) -> io::Result<()> {
    renameat2(source, destination, libc::RENAME_NOREPLACE)
}

fn renameat2(source: &Path, destination: &Path, flags: u32) -> io::Result<()> {
    let source = CString::new(source.as_os_str().as_bytes())
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    let destination = CString::new(destination.as_os_str().as_bytes())
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    let result = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            libc::AT_FDCWD,
            source.as_ptr(),
            libc::AT_FDCWD,
            destination.as_ptr(),
            flags,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}
