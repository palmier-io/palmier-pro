use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::path::{Path, PathBuf};

use futures::StreamExt;
use reqwest::header::CONTENT_LENGTH;
use reqwest::{Client, Url};
use tokio::io::AsyncWriteExt;
use tokio_util::sync::CancellationToken;

use crate::error::{GenerationError, Result};

pub const DEFAULT_MAX_DOWNLOAD_BYTES: u64 = 512 * 1024 * 1024;

#[derive(Debug, Clone, Copy)]
pub struct DownloadPolicy {
    pub max_bytes: u64,
    pub allow_loopback: bool,
}

impl Default for DownloadPolicy {
    fn default() -> Self {
        Self {
            max_bytes: DEFAULT_MAX_DOWNLOAD_BYTES,
            allow_loopback: false,
        }
    }
}

pub async fn download_bounded(
    client: &Client,
    url: &str,
    destination: &Path,
    policy: DownloadPolicy,
    cancel: &CancellationToken,
) -> Result<u64> {
    ensure_safe_download_url(url, policy.allow_loopback)?;
    if cancel.is_cancelled() {
        return Err(GenerationError::Cancelled);
    }
    let max_bytes = policy.max_bytes;

    let response = client
        .get(url)
        .send()
        .await
        .map_err(|error| GenerationError::Http(error.to_string()))?;
    if !response.status().is_success() {
        return Err(GenerationError::ProviderStatus {
            status: response.status().as_u16(),
            body: response.text().await.unwrap_or_else(|_| String::new()),
        });
    }

    if let Some(length) = response
        .headers()
        .get(CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok())
        && length > max_bytes
    {
        return Err(GenerationError::DownloadTooLarge { max_bytes });
    }

    if let Some(parent) = destination.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|source| GenerationError::Io {
                path: parent.to_path_buf(),
                source,
            })?;
    }

    let mut file = tokio::fs::File::create(destination)
        .await
        .map_err(|source| GenerationError::Io {
            path: destination.to_path_buf(),
            source,
        })?;

    let mut stream = response.bytes_stream();
    let mut written = 0_u64;
    while let Some(chunk) = stream.next().await {
        if cancel.is_cancelled() {
            let _ = tokio::fs::remove_file(destination).await;
            return Err(GenerationError::Cancelled);
        }
        let chunk = chunk.map_err(|error| GenerationError::Http(error.to_string()))?;
        written = written
            .checked_add(chunk.len() as u64)
            .ok_or(GenerationError::DownloadTooLarge { max_bytes })?;
        if written > max_bytes {
            let _ = tokio::fs::remove_file(destination).await;
            return Err(GenerationError::DownloadTooLarge { max_bytes });
        }
        file.write_all(&chunk)
            .await
            .map_err(|source| GenerationError::Io {
                path: destination.to_path_buf(),
                source,
            })?;
    }
    file.flush().await.map_err(|source| GenerationError::Io {
        path: destination.to_path_buf(),
        source,
    })?;
    Ok(written)
}

pub fn staged_result_path(
    stage_dir: &Path,
    job_id: &str,
    index: usize,
    extension: &str,
) -> PathBuf {
    stage_dir.join(format!("{job_id}-{index}.{extension}"))
}

pub fn ensure_safe_download_url(raw: &str, allow_loopback: bool) -> Result<Url> {
    let url =
        Url::parse(raw).map_err(|error| GenerationError::UnsafeDownloadUrl(error.to_string()))?;
    if url.scheme() != "https" && !(allow_loopback && url.scheme() == "http") {
        return Err(GenerationError::UnsafeDownloadUrl(format!(
            "unsupported scheme {}",
            url.scheme()
        )));
    }
    let host = url
        .host_str()
        .ok_or_else(|| GenerationError::UnsafeDownloadUrl("missing host".into()))?;
    let is_loopback_host = host.eq_ignore_ascii_case("localhost") || host.ends_with(".localhost");
    if is_loopback_host && !allow_loopback {
        return Err(GenerationError::UnsafeDownloadUrl(host.to_owned()));
    }
    if let Ok(ip) = host.parse::<IpAddr>() {
        let loopback = match ip {
            IpAddr::V4(v4) => v4.is_loopback(),
            IpAddr::V6(v6) => v6.is_loopback(),
        };
        if loopback && allow_loopback {
            return Ok(url);
        }
        if is_private_or_local(ip) {
            return Err(GenerationError::UnsafeDownloadUrl(host.to_owned()));
        }
    }
    Ok(url)
}

fn is_private_or_local(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_private_v4(v4),
        IpAddr::V6(v6) => is_private_v6(v6),
    }
}

fn is_private_v4(ip: Ipv4Addr) -> bool {
    ip.is_private()
        || ip.is_loopback()
        || ip.is_link_local()
        || ip.is_broadcast()
        || ip.is_unspecified()
        || ip.octets()[0] == 100 && (ip.octets()[1] & 0b1100_0000) == 0b0100_0000
}

fn is_private_v6(ip: Ipv6Addr) -> bool {
    ip.is_loopback() || ip.is_unspecified() || matches!(ip.segments()[0] & 0xffc0, 0xfc00 | 0xfe80)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_private_hosts() {
        assert!(ensure_safe_download_url("https://127.0.0.1/a", false).is_err());
        assert!(ensure_safe_download_url("https://10.0.0.2/a", false).is_err());
        assert!(ensure_safe_download_url("https://localhost/a", false).is_err());
        assert!(ensure_safe_download_url("http://127.0.0.1/a", true).is_ok());
    }
}
