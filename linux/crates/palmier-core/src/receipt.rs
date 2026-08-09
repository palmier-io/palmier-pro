use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MutationKind {
    AddClips,
    MoveClips,
    SplitClip,
    TrimClips,
    RemoveClips,
    Overwrite,
    RippleDelete,
    RippleInsert,
    LinkClips,
    UnlinkClips,
    AddTrack,
    RemoveTracks,
    ReorderTrack,
    UpdateTrack,
    UpsertKeyframe,
    RemoveKeyframe,
    MoveKeyframe,
    SetKeyframeInterpolation,
    PasteClips,
    ChangeProjectSettings,
    UpdateClips,
    CreateTimeline,
    SetActiveTimeline,
    UpdateMediaManifest,
    Batch,
    Undo,
    Redo,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MutationStatus {
    Applied,
    NoOp,
    Undone,
    Redone,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MutationReceipt {
    pub action: MutationKind,
    pub status: MutationStatus,
    pub revision_before: u64,
    pub revision_after: u64,
    pub timeline_id: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub created_clip_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub updated_clip_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub removed_clip_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub affected_track_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub created_track_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub removed_track_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub skipped_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub details: BTreeMap<String, Value>,
}

impl MutationReceipt {
    pub fn changed(&self) -> bool {
        self.revision_after != self.revision_before
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct MutationChanges {
    #[serde(default)]
    pub created_clip_ids: Vec<String>,
    #[serde(default)]
    pub updated_clip_ids: Vec<String>,
    #[serde(default)]
    pub removed_clip_ids: Vec<String>,
    #[serde(default)]
    pub affected_track_ids: Vec<String>,
    #[serde(default)]
    pub created_track_ids: Vec<String>,
    #[serde(default)]
    pub removed_track_ids: Vec<String>,
    #[serde(default)]
    pub skipped_ids: Vec<String>,
    #[serde(default)]
    pub warnings: Vec<String>,
}

impl MutationChanges {
    pub fn normalize(&mut self) {
        normalize_ids(&mut self.created_clip_ids);
        normalize_ids(&mut self.updated_clip_ids);
        normalize_ids(&mut self.removed_clip_ids);
        normalize_ids(&mut self.affected_track_ids);
        normalize_ids(&mut self.created_track_ids);
        normalize_ids(&mut self.removed_track_ids);
        normalize_ids(&mut self.skipped_ids);
    }

    pub fn merge(&mut self, other: Self) {
        self.created_clip_ids.extend(other.created_clip_ids);
        self.updated_clip_ids.extend(other.updated_clip_ids);
        self.removed_clip_ids.extend(other.removed_clip_ids);
        self.affected_track_ids.extend(other.affected_track_ids);
        self.created_track_ids.extend(other.created_track_ids);
        self.removed_track_ids.extend(other.removed_track_ids);
        self.skipped_ids.extend(other.skipped_ids);
        self.warnings.extend(other.warnings);
        self.normalize();
    }
}

fn normalize_ids(ids: &mut Vec<String>) {
    ids.sort();
    ids.dedup();
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MutationErrorCode {
    InvalidArgument,
    InvalidFrame,
    TimelineNotFound,
    TrackNotFound,
    ClipNotFound,
    DuplicateId,
    IncompatibleTrack,
    Collision,
    LinkNotEligible,
    MulticamAtomicity,
    NoUndo,
    NoRedo,
    ArithmeticOverflow,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MutationError {
    pub code: MutationErrorCode,
    pub message: String,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub details: BTreeMap<String, Value>,
}

impl MutationError {
    pub fn new(code: MutationErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            details: BTreeMap::new(),
        }
    }

    pub fn with_detail(mut self, key: impl Into<String>, value: impl Into<Value>) -> Self {
        self.details.insert(key.into(), value.into());
        self
    }
}

impl fmt::Display for MutationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for MutationError {}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CopyReceipt {
    pub copied_clip_ids: Vec<String>,
    pub entry_count: usize,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub skipped_ids: Vec<String>,
}
