use std::fs;
use std::path::{Component, Path, PathBuf};

use crate::{ProjectError, Result};

const MAX_FILENAME_BYTES: usize = 240;

pub fn validate_filename(name: &str) -> Result<()> {
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.starts_with('.')
        || name.contains('\\')
        || name.bytes().any(|byte| byte == 0 || byte < 0x20)
        || name.len() > 255
    {
        return Err(ProjectError::InvalidFilename(name.to_owned()));
    }
    let mut components = Path::new(name).components();
    if !matches!(components.next(), Some(Component::Normal(_))) || components.next().is_some() {
        return Err(ProjectError::InvalidFilename(name.to_owned()));
    }
    Ok(())
}

pub fn safe_filename(preferred: &str, fallback: &str) -> String {
    let fallback = sanitized_component(fallback);
    let fallback = if fallback.is_empty() {
        "media".to_owned()
    } else {
        fallback
    };
    let component = preferred
        .rsplit(['/', '\\'])
        .next()
        .map(sanitized_component)
        .filter(|name| !name.is_empty() && name != "." && name != "..")
        .unwrap_or_else(|| fallback.clone());
    truncate_filename(&component, MAX_FILENAME_BYTES)
}

pub fn unique_filename(directory: &Path, preferred: &str) -> Result<String> {
    Ok(unique_path(directory, preferred)?
        .file_name()
        .expect("unique path has a filename")
        .to_string_lossy()
        .into_owned())
}

pub fn unique_path(directory: &Path, preferred: &str) -> Result<PathBuf> {
    let safe = safe_filename(preferred, "media");
    validate_filename(&safe)?;
    let candidate = directory.join(&safe);
    match fs::symlink_metadata(&candidate) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(candidate);
        }
        Err(error) => {
            return Err(ProjectError::io(
                "inspect destination filename",
                &candidate,
                error,
            ));
        }
        Ok(_) => {}
    }

    let path = Path::new(&safe);
    let stem = path
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("media");
    let extension = path.extension().and_then(|extension| extension.to_str());
    for suffix in 1_u64.. {
        let suffix = format!("-{suffix}");
        let available = MAX_FILENAME_BYTES
            .saturating_sub(suffix.len())
            .saturating_sub(extension.map_or(0, |extension| extension.len() + 1));
        let stem = truncate_utf8(stem, available);
        let name = match extension {
            Some(extension) if !extension.is_empty() => {
                format!("{stem}{suffix}.{extension}")
            }
            _ => format!("{stem}{suffix}"),
        };
        let candidate = directory.join(name);
        match fs::symlink_metadata(&candidate) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(candidate);
            }
            Err(error) => {
                return Err(ProjectError::io(
                    "inspect destination filename",
                    &candidate,
                    error,
                ));
            }
            Ok(_) => {}
        }
    }
    unreachable!("filename suffix space is unbounded")
}

fn sanitized_component(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    let mut replacing = false;
    for character in input.trim().chars() {
        let invalid =
            character == '/' || character == '\\' || character == '\0' || character.is_control();
        if invalid {
            if !replacing {
                output.push('_');
            }
            replacing = true;
        } else {
            output.push(character);
            replacing = false;
        }
    }
    output
        .trim_matches(|character: char| character == '.' || character.is_whitespace())
        .to_owned()
}

fn truncate_filename(name: &str, max_bytes: usize) -> String {
    if name.len() <= max_bytes {
        return name.to_owned();
    }
    let path = Path::new(name);
    let stem = path
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("media");
    let extension = path.extension().and_then(|extension| extension.to_str());
    match extension {
        Some(extension) if extension.len() + 1 < max_bytes => {
            let stem = truncate_utf8(stem, max_bytes - extension.len() - 1);
            format!("{stem}.{extension}")
        }
        _ => truncate_utf8(name, max_bytes).to_owned(),
    }
}

fn truncate_utf8(value: &str, max_bytes: usize) -> &str {
    if value.len() <= max_bytes {
        return value;
    }
    let mut boundary = max_bytes;
    while boundary > 0 && !value.is_char_boundary(boundary) {
        boundary -= 1;
    }
    &value[..boundary]
}
