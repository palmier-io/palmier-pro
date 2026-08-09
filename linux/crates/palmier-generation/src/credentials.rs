use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use keyring::Entry;

use crate::catalog::ProviderKind;
use crate::error::{GenerationError, Result};

pub const SERVICE_NAME: &str = "palmier-pro";
pub const FAL_API_KEY: &str = "fal-api-key";
pub const REPLICATE_API_TOKEN: &str = "replicate-api-token";

pub trait CredentialStore: Send + Sync {
    fn get_secret(&self, key: &str) -> Result<Option<String>>;
    fn set_secret(&self, key: &str, value: &str) -> Result<()>;
    fn delete_secret(&self, key: &str) -> Result<()>;
}

#[derive(Debug, Default)]
pub struct MemoryCredentialStore {
    values: Mutex<HashMap<String, String>>,
}

impl MemoryCredentialStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_provider(provider: ProviderKind, value: impl Into<String>) -> Self {
        let store = Self::new();
        store
            .set_secret(provider.credential_key(), &value.into())
            .expect("memory credential store set");
        store
    }
}

impl CredentialStore for MemoryCredentialStore {
    fn get_secret(&self, key: &str) -> Result<Option<String>> {
        Ok(self
            .values
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(key)
            .cloned())
    }

    fn set_secret(&self, key: &str, value: &str) -> Result<()> {
        if value.trim().is_empty() {
            return Err(GenerationError::InvalidRequest(format!(
                "credential {key} must not be empty"
            )));
        }
        self.values
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(key.to_owned(), value.to_owned());
        Ok(())
    }

    fn delete_secret(&self, key: &str) -> Result<()> {
        self.values
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(key);
        Ok(())
    }
}

#[derive(Debug, Default, Clone)]
pub struct KeyringCredentialStore;

impl KeyringCredentialStore {
    pub fn new() -> Self {
        Self
    }

    fn entry(key: &str) -> Result<Entry> {
        Entry::new(SERVICE_NAME, key).map_err(|error| GenerationError::CredentialStoreUnavailable {
            key: key.to_owned(),
            detail: error.to_string(),
        })
    }
}

impl CredentialStore for KeyringCredentialStore {
    fn get_secret(&self, key: &str) -> Result<Option<String>> {
        let entry = Self::entry(key)?;
        match entry.get_password() {
            Ok(value) if !value.is_empty() => Ok(Some(value)),
            Ok(_) => Ok(None),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(error) => Err(map_keyring_error(key, error)),
        }
    }

    fn set_secret(&self, key: &str, value: &str) -> Result<()> {
        if value.trim().is_empty() {
            return Err(GenerationError::InvalidRequest(format!(
                "credential {key} must not be empty"
            )));
        }
        let entry = Self::entry(key)?;
        entry
            .set_password(value)
            .map_err(|error| map_keyring_error(key, error))
    }

    fn delete_secret(&self, key: &str) -> Result<()> {
        let entry = Self::entry(key)?;
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(map_keyring_error(key, error)),
        }
    }
}

fn map_keyring_error(key: &str, error: keyring::Error) -> GenerationError {
    let detail = error.to_string();
    let unavailable = matches!(
        error,
        keyring::Error::PlatformFailure(_)
            | keyring::Error::NoStorageAccess(_)
            | keyring::Error::Invalid(_, _)
    );
    if unavailable {
        GenerationError::CredentialStoreUnavailable {
            key: key.to_owned(),
            detail,
        }
    } else {
        GenerationError::CredentialStore {
            key: key.to_owned(),
            detail,
        }
    }
}

pub fn require_provider_credential(
    store: &dyn CredentialStore,
    provider: ProviderKind,
) -> Result<String> {
    let key = provider.credential_key();
    match store.get_secret(key)? {
        Some(value) if !value.trim().is_empty() => Ok(value),
        Some(_) | None => Err(GenerationError::CredentialMissing {
            provider: provider.as_str().to_owned(),
            key: key.to_owned(),
        }),
    }
}

pub type SharedCredentialStore = Arc<dyn CredentialStore>;
