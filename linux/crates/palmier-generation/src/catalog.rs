use std::collections::HashMap;
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};

use crate::error::{GenerationError, Result};

pub const CATALOG_VERSION: u32 = 1;
const CATALOG_JSON: &str = include_str!("../catalog/models.json");

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProviderKind {
    Fal,
    Replicate,
}

impl ProviderKind {
    pub fn credential_key(self) -> &'static str {
        match self {
            Self::Fal => "fal-api-key",
            Self::Replicate => "replicate-api-token",
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Fal => "fal",
            Self::Replicate => "replicate",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ModelKind {
    Video,
    Image,
    Audio,
    Upscale,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogModel {
    pub id: String,
    pub kind: ModelKind,
    pub display_name: String,
    pub provider: ProviderKind,
    pub endpoint: String,
    pub file_extension: String,
    #[serde(default)]
    pub aspect_ratios: Vec<String>,
    #[serde(default)]
    pub durations: Vec<i32>,
    #[serde(default)]
    pub max_references: u32,
    #[serde(default)]
    pub requires_source: bool,
    pub result_path: Vec<serde_json::Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CatalogFile {
    version: u32,
    models: Vec<CatalogModel>,
}

#[derive(Debug, Clone)]
pub struct ModelCatalog {
    version: u32,
    models: Vec<CatalogModel>,
    by_id: HashMap<String, usize>,
}

impl ModelCatalog {
    pub fn bundled() -> Result<&'static Self> {
        static CATALOG: OnceLock<ModelCatalog> = OnceLock::new();
        if let Some(catalog) = CATALOG.get() {
            return Ok(catalog);
        }
        let catalog = Self::from_json(CATALOG_JSON)?;
        Ok(CATALOG.get_or_init(|| catalog))
    }

    pub fn from_json(json: &str) -> Result<Self> {
        let file: CatalogFile = serde_json::from_str(json)
            .map_err(|error| GenerationError::Catalog(error.to_string()))?;
        if file.version != CATALOG_VERSION {
            return Err(GenerationError::Catalog(format!(
                "unsupported catalog version {} (expected {CATALOG_VERSION})",
                file.version
            )));
        }
        let mut by_id = HashMap::with_capacity(file.models.len());
        for (index, model) in file.models.iter().enumerate() {
            if by_id.insert(model.id.clone(), index).is_some() {
                return Err(GenerationError::Catalog(format!(
                    "duplicate model id {}",
                    model.id
                )));
            }
        }
        Ok(Self {
            version: file.version,
            models: file.models,
            by_id,
        })
    }

    pub fn version(&self) -> u32 {
        self.version
    }

    pub fn models(&self) -> &[CatalogModel] {
        &self.models
    }

    pub fn models_by_kind(&self, kind: ModelKind) -> impl Iterator<Item = &CatalogModel> {
        self.models.iter().filter(move |model| model.kind == kind)
    }

    pub fn get(&self, id: &str) -> Option<&CatalogModel> {
        self.by_id.get(id).map(|index| &self.models[*index])
    }

    pub fn require(&self, id: &str) -> Result<&CatalogModel> {
        self.get(id)
            .ok_or_else(|| GenerationError::ModelNotFound(id.to_owned()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_catalog_loads() {
        let catalog = ModelCatalog::bundled().expect("catalog");
        assert_eq!(catalog.version(), CATALOG_VERSION);
        assert!(catalog.get("flux-schnell").is_some());
        assert!(catalog.get("kling-video").is_some());
        assert!(catalog.get("stable-audio").is_some());
        assert!(catalog.get("real-esrgan").is_some());
        assert_eq!(catalog.models_by_kind(ModelKind::Image).count(), 2);
    }
}
