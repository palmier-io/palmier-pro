use std::collections::HashMap;
use std::hash::Hash;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use serde::{Deserialize, Serialize};

use crate::decode::DecodedFrame;
use crate::error::{IoResultExt, MediaError, Result};
use crate::time::MediaTime;

#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
pub struct AssetFingerprint {
    pub canonical_path: PathBuf,
    pub file_size: u64,
    pub modified_unix_nanos: i128,
    pub device: u64,
    pub inode: u64,
}

impl AssetFingerprint {
    pub async fn from_path(path: impl Into<PathBuf>) -> Result<Self> {
        let path = path.into();
        tokio::task::spawn_blocking(move || Self::from_path_blocking(&path))
            .await
            .map_err(|error| MediaError::BlockingTask(error.to_string()))?
    }

    fn from_path_blocking(path: &Path) -> Result<Self> {
        use std::os::unix::fs::MetadataExt;

        let canonical_path = std::fs::canonicalize(path).at_path(path)?;
        let metadata = std::fs::metadata(&canonical_path).at_path(&canonical_path)?;
        let modified_unix_nanos = i128::from(metadata.mtime())
            .checked_mul(1_000_000_000)
            .and_then(|seconds| seconds.checked_add(i128::from(metadata.mtime_nsec())))
            .ok_or(MediaError::ArithmeticOverflow(
                "asset modification timestamp",
            ))?;
        Ok(Self {
            canonical_path,
            file_size: metadata.len(),
            modified_unix_nanos,
            device: metadata.dev(),
            inode: metadata.ino(),
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ThumbnailFormat {
    Rgba,
    Jpeg { quality: u8 },
}

#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
pub struct ThumbnailKey {
    pub asset: AssetFingerprint,
    pub stream_index: Option<usize>,
    pub time: MediaTime,
    pub max_width: u32,
    pub max_height: u32,
    pub allow_upscale: bool,
    pub format: ThumbnailFormat,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WaveformChannelMode {
    Mixed,
    Separate,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
pub struct WaveformKey {
    pub asset: AssetFingerprint,
    pub stream_index: Option<usize>,
    pub start: MediaTime,
    pub duration: MediaTime,
    pub bucket_count: u32,
    pub channel_mode: WaveformChannelMode,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Waveform {
    pub channels: u16,
    pub bucket_count: u32,
    pub peaks: Vec<f32>,
}

pub trait CacheCost {
    fn cost_bytes(&self) -> usize;
}

impl CacheCost for Waveform {
    fn cost_bytes(&self) -> usize {
        self.peaks
            .capacity()
            .saturating_mul(std::mem::size_of::<f32>())
            .saturating_add(std::mem::size_of::<Self>())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CacheLimits {
    pub max_entries: usize,
    /// Bounds retained values as reported by `CacheCost`.
    pub max_bytes: usize,
}

impl CacheLimits {
    pub fn new(max_entries: usize, max_bytes: usize) -> Result<Self> {
        if max_entries == 0 || max_bytes == 0 {
            return Err(MediaError::InvalidRequest(
                "cache limits must be greater than zero".into(),
            ));
        }
        Ok(Self {
            max_entries,
            max_bytes,
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CacheInsertOutcome {
    Inserted,
    Replaced,
    RejectedOversized,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CacheStats {
    pub entries: usize,
    pub bytes: usize,
    pub hits: u64,
    pub misses: u64,
}

pub struct BoundedMediaCache<K, V> {
    limits: CacheLimits,
    state: Mutex<CacheState<K, V>>,
}

struct CacheState<K, V> {
    values: HashMap<K, CacheEntry<V>>,
    bytes: usize,
    tick: u64,
    hits: u64,
    misses: u64,
}

struct CacheEntry<V> {
    value: Arc<V>,
    bytes: usize,
    last_access: u64,
}

impl<K, V> BoundedMediaCache<K, V>
where
    K: Clone + Eq + Hash,
    V: CacheCost,
{
    pub fn new(limits: CacheLimits) -> Self {
        Self {
            limits,
            state: Mutex::new(CacheState {
                values: HashMap::new(),
                bytes: 0,
                tick: 0,
                hits: 0,
                misses: 0,
            }),
        }
    }

    pub fn get(&self, key: &K) -> Option<Arc<V>> {
        let mut state = self.lock_state();
        let tick = next_tick(&mut state);
        let value = if let Some(entry) = state.values.get_mut(key) {
            entry.last_access = tick;
            Some(Arc::clone(&entry.value))
        } else {
            None
        };
        if value.is_some() {
            state.hits = state.hits.saturating_add(1);
        } else {
            state.misses = state.misses.saturating_add(1);
        }
        value
    }

    pub fn insert(&self, key: K, value: V) -> CacheInsertOutcome {
        let bytes = value.cost_bytes();
        if bytes > self.limits.max_bytes {
            return CacheInsertOutcome::RejectedOversized;
        }

        let mut state = self.lock_state();
        let replaced = state.values.remove(&key);
        let did_replace = replaced.is_some();
        if let Some(entry) = &replaced {
            state.bytes = state.bytes.saturating_sub(entry.bytes);
        }
        let tick = next_tick(&mut state);
        state.bytes = match state.bytes.checked_add(bytes) {
            Some(total) => total,
            None => {
                if let Some(entry) = replaced {
                    state.bytes = state.bytes.saturating_add(entry.bytes);
                    state.values.insert(key, entry);
                }
                return CacheInsertOutcome::RejectedOversized;
            }
        };
        state.values.insert(
            key,
            CacheEntry {
                value: Arc::new(value),
                bytes,
                last_access: tick,
            },
        );

        while state.values.len() > self.limits.max_entries || state.bytes > self.limits.max_bytes {
            let Some(oldest_key) = state
                .values
                .iter()
                .min_by_key(|(_, entry)| entry.last_access)
                .map(|(key, _)| key.clone())
            else {
                break;
            };
            if let Some(entry) = state.values.remove(&oldest_key) {
                state.bytes = state.bytes.saturating_sub(entry.bytes);
            }
        }

        if did_replace {
            CacheInsertOutcome::Replaced
        } else {
            CacheInsertOutcome::Inserted
        }
    }

    pub fn remove(&self, key: &K) -> Option<Arc<V>> {
        let mut state = self.lock_state();
        state.values.remove(key).map(|entry| {
            state.bytes = state.bytes.saturating_sub(entry.bytes);
            entry.value
        })
    }

    pub fn clear(&self) {
        let mut state = self.lock_state();
        state.values.clear();
        state.bytes = 0;
        state.tick = 0;
    }

    pub fn stats(&self) -> CacheStats {
        let state = self.lock_state();
        CacheStats {
            entries: state.values.len(),
            bytes: state.bytes,
            hits: state.hits,
            misses: state.misses,
        }
    }

    fn lock_state(&self) -> MutexGuard<'_, CacheState<K, V>> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

fn next_tick<K, V>(state: &mut CacheState<K, V>) -> u64 {
    if state.tick == u64::MAX {
        let mut accesses: Vec<_> = state
            .values
            .values_mut()
            .map(|entry| &mut entry.last_access)
            .collect();
        accesses.sort_unstable_by_key(|value| **value);
        for (index, access) in accesses.into_iter().enumerate() {
            *access = index as u64;
        }
        state.tick = state.values.len() as u64;
    }
    state.tick += 1;
    state.tick
}

pub type ThumbnailCache = BoundedMediaCache<ThumbnailKey, DecodedFrame>;
pub type WaveformCache = BoundedMediaCache<WaveformKey, Waveform>;

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Clone)]
    struct Value(usize);

    impl CacheCost for Value {
        fn cost_bytes(&self) -> usize {
            self.0
        }
    }

    fn fingerprint(revision: i128) -> AssetFingerprint {
        AssetFingerprint {
            canonical_path: PathBuf::from("/media/clip.mov"),
            file_size: 10,
            modified_unix_nanos: revision,
            device: 1,
            inode: 2,
        }
    }

    #[test]
    fn thumbnail_key_includes_asset_revision_and_output_contract() {
        let base = ThumbnailKey {
            asset: fingerprint(1),
            stream_index: Some(0),
            time: MediaTime::ZERO,
            max_width: 320,
            max_height: 180,
            allow_upscale: false,
            format: ThumbnailFormat::Rgba,
        };
        let mut changed = base.clone();
        changed.asset = fingerprint(2);
        assert_ne!(base, changed);

        changed = base.clone();
        changed.format = ThumbnailFormat::Jpeg { quality: 80 };
        assert_ne!(base, changed);
    }

    #[test]
    fn waveform_key_includes_range_resolution_and_channel_mode() {
        let base = WaveformKey {
            asset: fingerprint(1),
            stream_index: Some(1),
            start: MediaTime::ZERO,
            duration: MediaTime::from_seconds(crate::ExactRational::from_integer(10)),
            bucket_count: 1_000,
            channel_mode: WaveformChannelMode::Mixed,
        };
        let mut changed = base.clone();
        changed.bucket_count = 2_000;
        assert_ne!(base, changed);

        changed = base.clone();
        changed.channel_mode = WaveformChannelMode::Separate;
        assert_ne!(base, changed);
    }

    #[test]
    fn cache_evicts_least_recently_used_entry_by_size() {
        let cache = BoundedMediaCache::new(CacheLimits::new(3, 10).unwrap());
        cache.insert("a", Value(4));
        cache.insert("b", Value(4));
        assert!(cache.get(&"a").is_some());
        cache.insert("c", Value(4));

        assert!(cache.get(&"a").is_some());
        assert!(cache.get(&"b").is_none());
        assert!(cache.get(&"c").is_some());
        assert!(cache.stats().bytes <= 10);
    }

    #[test]
    fn cache_rejects_single_oversized_value() {
        let cache = BoundedMediaCache::new(CacheLimits::new(2, 5).unwrap());

        assert_eq!(
            cache.insert("large", Value(6)),
            CacheInsertOutcome::RejectedOversized
        );
        assert_eq!(cache.stats().entries, 0);
    }
}
