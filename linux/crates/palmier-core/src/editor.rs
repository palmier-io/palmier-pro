use std::collections::{BTreeMap, HashMap, HashSet};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::frames::{Frame, FrameRange, checked_add, checked_sub, merge_ranges, swift_round};
use crate::models::{
    AnimatableProperty, Clip, ClipLocation, ClipType, Interpolation, Keyframe, KeyframeTrack,
    KeyframeValue, MediaManifest, ProjectFile, Timeline, Track, Transform, default_true, new_id,
};
use crate::overwrite::{OverwriteEngine, SplitError, split_clip_value};
use crate::receipt::{
    CopyReceipt, MutationChanges, MutationError, MutationErrorCode, MutationKind, MutationReceipt,
    MutationStatus,
};
use crate::ripple::{ClipShift, RippleEngine};

const HISTORY_LIMIT: usize = 100;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorSnapshot {
    pub project: ProjectFile,
    pub media_manifest: MediaManifest,
}

#[derive(Debug, Clone)]
struct HistoryEntry {
    action: MutationKind,
    timeline_id: String,
    before: EditorSnapshot,
    after: EditorSnapshot,
    changes: MutationChanges,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum AddMode {
    #[default]
    Overwrite,
    Ripple,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MoveClipRequest {
    pub clip_id: String,
    pub track_id: String,
    pub start_frame: Frame,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrimClipRequest {
    pub clip_id: String,
    pub trim_start_frame: Frame,
    pub trim_end_frame: Frame,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct TrackPatch {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub muted: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hidden: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sync_locked: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_height: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipClipboardEntry {
    pub clip: Clip,
    pub track_offset: i64,
    pub frame_offset: Frame,
    pub source_track_id: String,
    pub source_track_type: ClipType,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "command", rename_all = "camelCase")]
pub enum EditorCommand {
    AddClips {
        timeline_id: String,
        track_id: String,
        start_frame: Frame,
        clips: Vec<Clip>,
        #[serde(default)]
        mode: AddMode,
    },
    MoveClips {
        timeline_id: String,
        moves: Vec<MoveClipRequest>,
    },
    SplitClip {
        timeline_id: String,
        clip_id: String,
        at_frame: Frame,
    },
    TrimClips {
        timeline_id: String,
        edits: Vec<TrimClipRequest>,
    },
    RemoveClips {
        timeline_id: String,
        clip_ids: Vec<String>,
        #[serde(default)]
        prune_empty_tracks: bool,
    },
    Overwrite {
        timeline_id: String,
        track_id: String,
        range: FrameRange,
    },
    RippleDelete {
        timeline_id: String,
        track_id: String,
        ranges: Vec<FrameRange>,
        #[serde(default)]
        ignored_sync_locked_track_ids: Vec<String>,
    },
    LinkClips {
        timeline_id: String,
        clip_ids: Vec<String>,
    },
    UnlinkClips {
        timeline_id: String,
        clip_ids: Vec<String>,
    },
    AddTrack {
        timeline_id: String,
        track_type: ClipType,
        requested_index: usize,
    },
    RemoveTracks {
        timeline_id: String,
        track_ids: Vec<String>,
    },
    ReorderTrack {
        timeline_id: String,
        track_id: String,
        target_index: usize,
    },
    UpdateTrack {
        timeline_id: String,
        track_id: String,
        patch: TrackPatch,
    },
    UpsertKeyframe {
        timeline_id: String,
        clip_id: String,
        property: AnimatableProperty,
        frame: Frame,
        value: KeyframeValue,
    },
    RemoveKeyframe {
        timeline_id: String,
        clip_id: String,
        property: AnimatableProperty,
        frame: Frame,
    },
    MoveKeyframe {
        timeline_id: String,
        clip_id: String,
        property: AnimatableProperty,
        from_frame: Frame,
        to_frame: Frame,
    },
    SetKeyframeInterpolation {
        timeline_id: String,
        clip_id: String,
        property: AnimatableProperty,
        frame: Frame,
        interpolation: Interpolation,
    },
    PasteClips {
        timeline_id: String,
        track_id: String,
        start_frame: Frame,
    },
    ChangeProjectSettings {
        timeline_id: String,
        fps: i32,
        width: i32,
        height: i32,
    },
    UpdateClips {
        timeline_id: String,
        clips: Vec<Clip>,
    },
    SetClipSpeed {
        timeline_id: String,
        clip_ids: Vec<String>,
        speed: f64,
        #[serde(default = "default_true")]
        ripple: bool,
    },
    SetClipFades {
        timeline_id: String,
        clip_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        fade_in_frames: Option<Frame>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        fade_out_frames: Option<Frame>,
    },
    SlipClips {
        timeline_id: String,
        clip_id: String,
        delta_frames: Frame,
        #[serde(default = "default_true")]
        propagate_to_linked: bool,
    },
    CreateTimeline {
        timeline: Timeline,
        #[serde(default)]
        make_active: bool,
    },
    SetActiveTimeline {
        timeline_id: String,
    },
    UpdateMediaManifest {
        timeline_id: String,
        media_manifest: MediaManifest,
    },
    Batch {
        timeline_id: String,
        commands: Vec<EditorCommand>,
    },
    Undo,
    Redo,
}

#[derive(Debug, Clone)]
struct TransactionResult {
    changes: MutationChanges,
    details: BTreeMap<String, Value>,
}

impl TransactionResult {
    fn new(changes: MutationChanges) -> Self {
        Self {
            changes,
            details: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct EditorSession {
    project: ProjectFile,
    media_manifest: MediaManifest,
    revision: u64,
    undo_stack: Vec<HistoryEntry>,
    redo_stack: Vec<HistoryEntry>,
    clipboard: Vec<ClipClipboardEntry>,
}

impl EditorSession {
    pub fn new(project: ProjectFile) -> Result<Self, MutationError> {
        Self::with_manifest(project, MediaManifest::default())
    }

    pub fn with_manifest(
        mut project: ProjectFile,
        media_manifest: MediaManifest,
    ) -> Result<Self, MutationError> {
        validate_project(&project)?;
        project.normalize_navigation();
        Ok(Self {
            project,
            media_manifest,
            revision: 0,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            clipboard: Vec::new(),
        })
    }

    pub fn project(&self) -> &ProjectFile {
        &self.project
    }

    pub fn media_manifest(&self) -> &MediaManifest {
        &self.media_manifest
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }

    pub fn undo_depth(&self) -> usize {
        self.undo_stack.len()
    }

    pub fn redo_depth(&self) -> usize {
        self.redo_stack.len()
    }

    pub fn clipboard(&self) -> &[ClipClipboardEntry] {
        &self.clipboard
    }

    pub fn snapshot(&self) -> EditorSnapshot {
        EditorSnapshot {
            project: self.project.clone(),
            media_manifest: self.media_manifest.clone(),
        }
    }

    pub fn set_media_manifest(&mut self, media_manifest: MediaManifest) {
        self.media_manifest = media_manifest;
    }

    pub fn preview(
        &self,
        command: EditorCommand,
    ) -> Result<(MutationReceipt, EditorSnapshot), MutationError> {
        let mut session = self.clone();
        let receipt = session.execute(command)?;
        Ok((receipt, session.snapshot()))
    }

    pub fn execute(&mut self, command: EditorCommand) -> Result<MutationReceipt, MutationError> {
        match command {
            EditorCommand::AddClips {
                timeline_id,
                track_id,
                start_frame,
                clips,
                mode,
            } => self.add_clips(&timeline_id, &track_id, start_frame, clips, mode),
            EditorCommand::MoveClips { timeline_id, moves } => self.move_clips(&timeline_id, moves),
            EditorCommand::SplitClip {
                timeline_id,
                clip_id,
                at_frame,
            } => self.split_clip(&timeline_id, &clip_id, at_frame),
            EditorCommand::TrimClips { timeline_id, edits } => self.trim_clips(&timeline_id, edits),
            EditorCommand::RemoveClips {
                timeline_id,
                clip_ids,
                prune_empty_tracks,
            } => self.remove_clips(&timeline_id, &clip_ids, prune_empty_tracks),
            EditorCommand::Overwrite {
                timeline_id,
                track_id,
                range,
            } => self.overwrite(&timeline_id, &track_id, range),
            EditorCommand::RippleDelete {
                timeline_id,
                track_id,
                ranges,
                ignored_sync_locked_track_ids,
            } => self.ripple_delete_ranges(
                &timeline_id,
                &track_id,
                &ranges,
                &ignored_sync_locked_track_ids.into_iter().collect(),
            ),
            EditorCommand::LinkClips {
                timeline_id,
                clip_ids,
            } => self.link_clips(&timeline_id, &clip_ids),
            EditorCommand::UnlinkClips {
                timeline_id,
                clip_ids,
            } => self.unlink_clips(&timeline_id, &clip_ids),
            EditorCommand::AddTrack {
                timeline_id,
                track_type,
                requested_index,
            } => self.add_track(&timeline_id, track_type, requested_index),
            EditorCommand::RemoveTracks {
                timeline_id,
                track_ids,
            } => self.remove_tracks(&timeline_id, &track_ids),
            EditorCommand::ReorderTrack {
                timeline_id,
                track_id,
                target_index,
            } => self.reorder_track(&timeline_id, &track_id, target_index),
            EditorCommand::UpdateTrack {
                timeline_id,
                track_id,
                patch,
            } => self.update_track(&timeline_id, &track_id, patch),
            EditorCommand::UpsertKeyframe {
                timeline_id,
                clip_id,
                property,
                frame,
                value,
            } => self.upsert_keyframe(&timeline_id, &clip_id, property, frame, value),
            EditorCommand::RemoveKeyframe {
                timeline_id,
                clip_id,
                property,
                frame,
            } => self.remove_keyframe(&timeline_id, &clip_id, property, frame),
            EditorCommand::MoveKeyframe {
                timeline_id,
                clip_id,
                property,
                from_frame,
                to_frame,
            } => self.move_keyframe(&timeline_id, &clip_id, property, from_frame, to_frame),
            EditorCommand::SetKeyframeInterpolation {
                timeline_id,
                clip_id,
                property,
                frame,
                interpolation,
            } => self.set_keyframe_interpolation(
                &timeline_id,
                &clip_id,
                property,
                frame,
                interpolation,
            ),
            EditorCommand::PasteClips {
                timeline_id,
                track_id,
                start_frame,
            } => self.paste_clips(&timeline_id, &track_id, start_frame),
            EditorCommand::ChangeProjectSettings {
                timeline_id,
                fps,
                width,
                height,
            } => self.apply_project_settings(&timeline_id, fps, width, height),
            EditorCommand::UpdateClips {
                timeline_id,
                clips,
            } => self.update_clips(&timeline_id, clips),
            EditorCommand::SetClipSpeed {
                timeline_id,
                clip_ids,
                speed,
                ripple,
            } => self.set_clip_speed(&timeline_id, &clip_ids, speed, ripple),
            EditorCommand::SetClipFades {
                timeline_id,
                clip_id,
                fade_in_frames,
                fade_out_frames,
            } => self.set_clip_fades(&timeline_id, &clip_id, fade_in_frames, fade_out_frames),
            EditorCommand::SlipClips {
                timeline_id,
                clip_id,
                delta_frames,
                propagate_to_linked,
            } => self.slip_clips(&timeline_id, &clip_id, delta_frames, propagate_to_linked),
            EditorCommand::CreateTimeline {
                timeline,
                make_active,
            } => self.create_timeline(timeline, make_active),
            EditorCommand::SetActiveTimeline { timeline_id } => {
                self.set_active_timeline(&timeline_id)
            }
            EditorCommand::UpdateMediaManifest {
                timeline_id,
                media_manifest,
            } => self.update_media_manifest(&timeline_id, media_manifest),
            EditorCommand::Batch {
                timeline_id,
                commands,
            } => self.execute_batch(&timeline_id, commands),
            EditorCommand::Undo => self.undo(),
            EditorCommand::Redo => self.redo(),
        }
    }

    pub fn add_clips(
        &mut self,
        timeline_id: &str,
        track_id: &str,
        start_frame: Frame,
        mut clips: Vec<Clip>,
        mode: AddMode,
    ) -> Result<MutationReceipt, MutationError> {
        if start_frame < 0 {
            return Err(invalid_frame("startFrame must not be negative"));
        }
        let timeline_index = self.timeline_index(timeline_id)?;
        let track_index = self.track_index(timeline_index, track_id)?;
        let track_type = self.project.timelines[timeline_index].tracks[track_index].track_type;
        let existing_ids = all_clip_ids(&self.project);
        let mut request_ids = HashSet::new();
        let mut cursor = start_frame;
        for clip in &mut clips {
            if clip.id.is_empty() {
                clip.id = new_id();
            }
            if !request_ids.insert(clip.id.clone()) || existing_ids.contains(&clip.id) {
                return Err(MutationError::new(
                    MutationErrorCode::DuplicateId,
                    format!("clip id is already in use: {}", clip.id),
                ));
            }
            validate_clip_for_mutation(clip)?;
            if !track_type.is_compatible_with(clip.media_type) {
                return Err(MutationError::new(
                    MutationErrorCode::IncompatibleTrack,
                    format!("clip {} is not compatible with track {track_id}", clip.id),
                ));
            }
            clip.start_frame = cursor;
            cursor = checked_add(cursor, clip.duration_frames).map_err(frame_error)?;
        }
        let total_duration = checked_sub(cursor, start_frame).map_err(frame_error)?;

        self.transact(MutationKind::AddClips, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let track_index = session.track_index(timeline_index, track_id)?;
            let mut changes = MutationChanges::default();

            if !clips.is_empty() && total_duration > 0 {
                match mode {
                    AddMode::Overwrite => {
                        let report = OverwriteEngine::clear_region(
                            &mut session.project.timelines[timeline_index].tracks[track_index]
                                .clips,
                            FrameRange {
                                start: start_frame,
                                end: cursor,
                            },
                            &[],
                        )
                        .map_err(split_error)?;
                        append_overwrite_changes(&mut changes, report);
                    }
                    AddMode::Ripple => {
                        let target_track_id = track_id.to_owned();
                        let pushed_track_ids = session.project.timelines[timeline_index]
                            .tracks
                            .iter()
                            .filter(|track| track.id == target_track_id || track.sync_locked)
                            .map(|track| track.id.clone())
                            .collect::<Vec<_>>();
                        for pushed_track_id in pushed_track_ids {
                            let index = session.track_index(timeline_index, &pushed_track_id)?;
                            split_straddler(
                                &mut session.project.timelines[timeline_index].tracks[index],
                                start_frame,
                                &mut changes,
                            )?;
                            let shifts = RippleEngine::push(
                                &session.project.timelines[timeline_index].tracks[index].clips,
                                start_frame,
                                total_duration,
                                &HashSet::new(),
                            );
                            apply_shifts(
                                &mut session.project.timelines[timeline_index].tracks[index],
                                &shifts,
                                &mut changes,
                            );
                            changes.affected_track_ids.push(pushed_track_id);
                        }
                    }
                }
            }

            let target = &mut session.project.timelines[timeline_index].tracks[track_index];
            for clip in clips {
                changes.created_clip_ids.push(clip.id.clone());
                target.clips.push(clip);
            }
            target.sort_clips();
            if !changes.created_clip_ids.is_empty()
                || !changes.updated_clip_ids.is_empty()
                || !changes.removed_clip_ids.is_empty()
            {
                changes.affected_track_ids.push(track_id.to_owned());
            }
            Ok(TransactionResult::new(changes))
        })
    }

    pub fn overwrite(
        &mut self,
        timeline_id: &str,
        track_id: &str,
        range: FrameRange,
    ) -> Result<MutationReceipt, MutationError> {
        validate_range(range)?;
        self.timeline_index(timeline_id)
            .and_then(|index| self.track_index(index, track_id).map(|_| ()))?;
        self.transact(MutationKind::Overwrite, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let track_index = session.track_index(timeline_index, track_id)?;
            let report = OverwriteEngine::clear_region(
                &mut session.project.timelines[timeline_index].tracks[track_index].clips,
                range,
                &[],
            )
            .map_err(split_error)?;
            let mut changes = MutationChanges::default();
            append_overwrite_changes(&mut changes, report);
            if !changes.updated_clip_ids.is_empty()
                || !changes.created_clip_ids.is_empty()
                || !changes.removed_clip_ids.is_empty()
            {
                changes.affected_track_ids.push(track_id.to_owned());
            }
            Ok(TransactionResult::new(changes))
        })
    }

    pub fn move_clips(
        &mut self,
        timeline_id: &str,
        moves: Vec<MoveClipRequest>,
    ) -> Result<MutationReceipt, MutationError> {
        let timeline_index = self.timeline_index(timeline_id)?;
        if moves.is_empty() {
            return self.no_op_receipt(MutationKind::MoveClips, timeline_id);
        }
        let mut seen = HashSet::new();
        let mut plans = Vec::new();
        for request in moves {
            if !seen.insert(request.clip_id.clone()) {
                return Err(MutationError::new(
                    MutationErrorCode::DuplicateId,
                    format!("clip appears more than once: {}", request.clip_id),
                ));
            }
            if request.start_frame < 0 {
                return Err(invalid_frame("move startFrame must not be negative"));
            }
            let location = self.clip_location(timeline_index, &request.clip_id)?;
            let destination = self.track_index(timeline_index, &request.track_id)?;
            let clip = self.project.timelines[timeline_index].tracks[location.track_index].clips
                [location.clip_index]
                .clone();
            let destination_type =
                self.project.timelines[timeline_index].tracks[destination].track_type;
            if !destination_type.is_compatible_with(clip.media_type) {
                return Err(MutationError::new(
                    MutationErrorCode::IncompatibleTrack,
                    format!(
                        "clip {} is not compatible with track {}",
                        request.clip_id, request.track_id
                    ),
                ));
            }
            checked_add(request.start_frame, clip.duration_frames).map_err(frame_error)?;
            plans.push((request, clip));
        }
        if plans.iter().all(|(request, clip)| {
            self.project.timelines[timeline_index]
                .clip_location(&request.clip_id)
                .is_some_and(|location| {
                    self.project.timelines[timeline_index].tracks[location.track_index].id
                        == request.track_id
                        && clip.start_frame == request.start_frame
                })
        }) {
            return self.no_op_receipt(MutationKind::MoveClips, timeline_id);
        }
        for left in 0..plans.len() {
            for right in left + 1..plans.len() {
                if plans[left].0.track_id != plans[right].0.track_id {
                    continue;
                }
                let left_range = FrameRange {
                    start: plans[left].0.start_frame,
                    end: plans[left].0.start_frame + plans[left].1.duration_frames,
                };
                let right_range = FrameRange {
                    start: plans[right].0.start_frame,
                    end: plans[right].0.start_frame + plans[right].1.duration_frames,
                };
                if left_range.overlaps(right_range) {
                    return Err(MutationError::new(
                        MutationErrorCode::Collision,
                        "moved clips would overlap each other",
                    ));
                }
            }
        }

        self.transact(MutationKind::MoveClips, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let moved_ids: HashSet<_> = plans
                .iter()
                .map(|(request, _)| request.clip_id.clone())
                .collect();
            let mut changes = MutationChanges::default();
            for track in &mut session.project.timelines[timeline_index].tracks {
                track.clips.retain(|clip| !moved_ids.contains(&clip.id));
            }
            for (request, clip) in &plans {
                let destination = session.track_index(timeline_index, &request.track_id)?;
                let report = OverwriteEngine::clear_region(
                    &mut session.project.timelines[timeline_index].tracks[destination].clips,
                    FrameRange {
                        start: request.start_frame,
                        end: request.start_frame + clip.duration_frames,
                    },
                    &[],
                )
                .map_err(split_error)?;
                append_overwrite_changes(&mut changes, report);
            }
            for (request, mut clip) in plans {
                let destination = session.track_index(timeline_index, &request.track_id)?;
                clip.start_frame = request.start_frame;
                session.project.timelines[timeline_index].tracks[destination]
                    .clips
                    .push(clip);
                changes.updated_clip_ids.push(request.clip_id);
                changes.affected_track_ids.push(request.track_id);
            }
            for track in &mut session.project.timelines[timeline_index].tracks {
                track.sort_clips();
            }
            let destination_ids: HashSet<_> = changes.affected_track_ids.iter().cloned().collect();
            let removed_tracks = session.project.timelines[timeline_index]
                .tracks
                .iter()
                .filter(|track| track.clips.is_empty() && !destination_ids.contains(&track.id))
                .map(|track| track.id.clone())
                .collect::<Vec<_>>();
            session.project.timelines[timeline_index]
                .tracks
                .retain(|track| !removed_tracks.contains(&track.id));
            changes.removed_track_ids.extend(removed_tracks);
            Ok(TransactionResult::new(changes))
        })
    }

    pub fn split_clip(
        &mut self,
        timeline_id: &str,
        clip_id: &str,
        at_frame: Frame,
    ) -> Result<MutationReceipt, MutationError> {
        let timeline_index = self.timeline_index(timeline_id)?;
        let location = self.clip_location(timeline_index, clip_id)?;
        let anchor = &self.project.timelines[timeline_index].tracks[location.track_index].clips
            [location.clip_index];
        if at_frame <= anchor.start_frame || at_frame >= anchor.end_frame() {
            return self.no_op_receipt(MutationKind::SplitClip, timeline_id);
        }
        self.transact(MutationKind::SplitClip, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let anchor_location = session.clip_location(timeline_index, clip_id)?;
            let anchor = session.project.timelines[timeline_index].tracks
                [anchor_location.track_index]
                .clips[anchor_location.clip_index]
                .clone();
            let target_ids = if let Some(group_id) = &anchor.link_group_id {
                session.project.timelines[timeline_index]
                    .tracks
                    .iter()
                    .flat_map(|track| &track.clips)
                    .filter(|clip| clip.link_group_id.as_ref() == Some(group_id))
                    .map(|clip| clip.id.clone())
                    .collect::<Vec<_>>()
            } else {
                vec![clip_id.to_owned()]
            };
            let target_count = target_ids.len();
            let mut right_ids = Vec::new();
            let mut changes = MutationChanges::default();
            for target_id in target_ids {
                let Some(location) =
                    session.project.timelines[timeline_index].clip_location(&target_id)
                else {
                    continue;
                };
                let original = session.project.timelines[timeline_index].tracks
                    [location.track_index]
                    .clips[location.clip_index]
                    .clone();
                if at_frame <= original.start_frame || at_frame >= original.end_frame() {
                    continue;
                }
                let (left, right) =
                    split_clip_value(&original, at_frame, new_id()).map_err(split_error)?;
                let right_id = right.id.clone();
                let track =
                    &mut session.project.timelines[timeline_index].tracks[location.track_index];
                track.clips[location.clip_index] = left;
                track.clips.push(right);
                track.sort_clips();
                changes.updated_clip_ids.push(target_id);
                changes.created_clip_ids.push(right_id.clone());
                changes.affected_track_ids.push(track.id.clone());
                right_ids.push(right_id);
            }
            if target_count > 1 && !right_ids.is_empty() {
                let group = new_id();
                for right_id in &right_ids {
                    if let Some(location) =
                        session.project.timelines[timeline_index].clip_location(right_id)
                    {
                        session.project.timelines[timeline_index].tracks[location.track_index]
                            .clips[location.clip_index]
                            .link_group_id = Some(group.clone());
                    }
                }
            }
            Ok(TransactionResult::new(changes))
        })
    }

    pub fn trim_clips(
        &mut self,
        timeline_id: &str,
        edits: Vec<TrimClipRequest>,
    ) -> Result<MutationReceipt, MutationError> {
        let timeline_index = self.timeline_index(timeline_id)?;
        let mut seen = HashSet::new();
        for edit in &edits {
            if !seen.insert(edit.clip_id.clone()) {
                return Err(MutationError::new(
                    MutationErrorCode::DuplicateId,
                    format!("clip appears more than once: {}", edit.clip_id),
                ));
            }
            let location = self.clip_location(timeline_index, &edit.clip_id)?;
            let clip = &self.project.timelines[timeline_index].tracks[location.track_index].clips
                [location.clip_index];
            validate_trim(clip, edit)?;
        }
        self.transact(MutationKind::TrimClips, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let protected: Vec<_> = edits.iter().map(|edit| edit.clip_id.clone()).collect();
            let mut changes = MutationChanges::default();
            for edit in edits {
                let location = session.clip_location(timeline_index, &edit.clip_id)?;
                let original = session.project.timelines[timeline_index].tracks
                    [location.track_index]
                    .clips[location.clip_index]
                    .clone();
                if original.trim_start_frame == edit.trim_start_frame
                    && original.trim_end_frame == edit.trim_end_frame
                {
                    continue;
                }
                let (new_start, new_duration) = trim_geometry(&original, &edit)?;
                let previous_end = original.end_frame();
                let new_end = checked_add(new_start, new_duration).map_err(frame_error)?;
                if new_start < original.start_frame {
                    let report = OverwriteEngine::clear_region(
                        &mut session.project.timelines[timeline_index].tracks[location.track_index]
                            .clips,
                        FrameRange {
                            start: new_start,
                            end: original.start_frame,
                        },
                        &protected,
                    )
                    .map_err(split_error)?;
                    append_overwrite_changes(&mut changes, report);
                }
                if new_end > previous_end {
                    let report = OverwriteEngine::clear_region(
                        &mut session.project.timelines[timeline_index].tracks[location.track_index]
                            .clips,
                        FrameRange {
                            start: previous_end,
                            end: new_end,
                        },
                        &protected,
                    )
                    .map_err(split_error)?;
                    append_overwrite_changes(&mut changes, report);
                }
                let location = session.clip_location(timeline_index, &edit.clip_id)?;
                let track =
                    &mut session.project.timelines[timeline_index].tracks[location.track_index];
                let clip = &mut track.clips[location.clip_index];
                clip.trim_start_frame = edit.trim_start_frame;
                clip.trim_end_frame = edit.trim_end_frame;
                clip.start_frame = new_start;
                clip.set_duration(new_duration);
                track.sort_clips();
                changes.updated_clip_ids.push(edit.clip_id);
                changes.affected_track_ids.push(track.id.clone());
            }
            Ok(TransactionResult::new(changes))
        })
    }

    pub fn remove_clips(
        &mut self,
        timeline_id: &str,
        clip_ids: &[String],
        prune_empty_tracks: bool,
    ) -> Result<MutationReceipt, MutationError> {
        let timeline_index = self.timeline_index(timeline_id)?;
        ensure_unique_ids(clip_ids, "clip")?;
        for clip_id in clip_ids {
            self.clip_location(timeline_index, clip_id)?;
        }
        let ids: HashSet<_> = clip_ids.iter().cloned().collect();
        self.transact(MutationKind::RemoveClips, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let mut changes = MutationChanges {
                removed_clip_ids: ids.iter().cloned().collect(),
                ..MutationChanges::default()
            };
            for track in &mut session.project.timelines[timeline_index].tracks {
                let before = track.clips.len();
                track.clips.retain(|clip| !ids.contains(&clip.id));
                if before != track.clips.len() {
                    changes.affected_track_ids.push(track.id.clone());
                }
            }
            if prune_empty_tracks {
                let removed = session.project.timelines[timeline_index]
                    .tracks
                    .iter()
                    .filter(|track| track.clips.is_empty())
                    .map(|track| track.id.clone())
                    .collect::<Vec<_>>();
                session.project.timelines[timeline_index]
                    .tracks
                    .retain(|track| !track.clips.is_empty());
                changes.removed_track_ids.extend(removed);
            }
            Ok(TransactionResult::new(changes))
        })
    }

    pub fn ripple_delete_ranges(
        &mut self,
        timeline_id: &str,
        track_id: &str,
        ranges: &[FrameRange],
        ignored_sync_locked_track_ids: &HashSet<String>,
    ) -> Result<MutationReceipt, MutationError> {
        let timeline_index = self.timeline_index(timeline_id)?;
        self.track_index(timeline_index, track_id)?;
        for range in ranges {
            validate_range(*range)?;
        }
        let merged = merge_ranges(ranges.iter().copied());
        if merged.is_empty() {
            return Err(MutationError::new(
                MutationErrorCode::InvalidFrame,
                "no non-empty ranges to delete",
            ));
        }
        for ignored in ignored_sync_locked_track_ids {
            self.track_index(timeline_index, ignored)?;
        }
        let clear_track_ids = ripple_clear_track_ids(
            &self.project.timelines[timeline_index],
            track_id,
            &merged,
            ignored_sync_locked_track_ids,
        );
        validate_multicam_atomicity(&self.project.timelines[timeline_index], &clear_track_ids)?;

        self.transact(MutationKind::RippleDelete, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let mut changes = MutationChanges::default();
            let mut removed_frames = 0_i64;
            for range in &merged {
                removed_frames =
                    checked_add(removed_frames, range.length()).map_err(frame_error)?;
            }
            for clear_track_id in &clear_track_ids {
                let track_index = session.track_index(timeline_index, clear_track_id)?;
                for range in &merged {
                    let report = OverwriteEngine::clear_region(
                        &mut session.project.timelines[timeline_index].tracks[track_index].clips,
                        *range,
                        &[],
                    )
                    .map_err(split_error)?;
                    append_overwrite_changes(&mut changes, report);
                }
            }
            let mut shifted_count = 0_usize;
            for clear_track_id in &clear_track_ids {
                let track_index = session.track_index(timeline_index, clear_track_id)?;
                let shifts = RippleEngine::shifts_for_ranges(
                    &session.project.timelines[timeline_index].tracks[track_index].clips,
                    &merged,
                );
                shifted_count += shifts.len();
                apply_shifts(
                    &mut session.project.timelines[timeline_index].tracks[track_index],
                    &shifts,
                    &mut changes,
                );
                session.project.timelines[timeline_index].tracks[track_index].sort_clips();
                changes.affected_track_ids.push(clear_track_id.clone());
            }
            let mut result = TransactionResult::new(changes);
            result
                .details
                .insert("removedFrames".to_owned(), json!(removed_frames));
            result
                .details
                .insert("clearedTracks".to_owned(), json!(clear_track_ids.len()));
            result
                .details
                .insert("shiftedClips".to_owned(), json!(shifted_count));
            result.details.insert(
                "ranges".to_owned(),
                serde_json::to_value(&merged).unwrap_or(Value::Null),
            );
            Ok(result)
        })
    }

    pub fn link_clips(
        &mut self,
        timeline_id: &str,
        clip_ids: &[String],
    ) -> Result<MutationReceipt, MutationError> {
        let timeline_index = self.timeline_index(timeline_id)?;
        ensure_unique_ids(clip_ids, "clip")?;
        for clip_id in clip_ids {
            self.clip_location(timeline_index, clip_id)?;
        }
        let expanded = expand_link_groups(
            &self.project.timelines[timeline_index],
            &clip_ids.iter().cloned().collect(),
        );
        if expanded.len() < 2 {
            return self.no_op_receipt(MutationKind::LinkClips, timeline_id);
        }
        let clips = expanded
            .iter()
            .filter_map(|id| {
                let location = self.project.timelines[timeline_index].clip_location(id)?;
                Some(
                    &self.project.timelines[timeline_index].tracks[location.track_index].clips
                        [location.clip_index],
                )
            })
            .collect::<Vec<_>>();
        if clips.len() != expanded.len() {
            return Err(MutationError::new(
                MutationErrorCode::ClipNotFound,
                "one or more clips no longer exist",
            ));
        }
        if clips
            .iter()
            .map(|clip| clip.media_type)
            .collect::<HashSet<_>>()
            .len()
            < 2
        {
            return Err(MutationError::new(
                MutationErrorCode::LinkNotEligible,
                "linking requires at least two media types",
            ));
        }
        let groups = clips
            .iter()
            .filter_map(|clip| clip.link_group_id.clone())
            .collect::<HashSet<_>>();
        let ungrouped = clips
            .iter()
            .filter(|clip| clip.link_group_id.is_none())
            .count();
        if groups.len() == 1 && ungrouped == 0 {
            return self.no_op_receipt(MutationKind::LinkClips, timeline_id);
        }

        self.transact(MutationKind::LinkClips, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let group = new_id();
            let mut changes = MutationChanges::default();
            for clip_id in &expanded {
                let location = session.clip_location(timeline_index, clip_id)?;
                let track =
                    &mut session.project.timelines[timeline_index].tracks[location.track_index];
                track.clips[location.clip_index].link_group_id = Some(group.clone());
                changes.updated_clip_ids.push(clip_id.clone());
                changes.affected_track_ids.push(track.id.clone());
            }
            let mut result = TransactionResult::new(changes);
            result
                .details
                .insert("linkGroupId".to_owned(), json!(group));
            Ok(result)
        })
    }

    pub fn unlink_clips(
        &mut self,
        timeline_id: &str,
        clip_ids: &[String],
    ) -> Result<MutationReceipt, MutationError> {
        let timeline_index = self.timeline_index(timeline_id)?;
        ensure_unique_ids(clip_ids, "clip")?;
        for clip_id in clip_ids {
            self.clip_location(timeline_index, clip_id)?;
        }
        let expanded = expand_link_groups(
            &self.project.timelines[timeline_index],
            &clip_ids.iter().cloned().collect(),
        );
        let targets = expanded
            .into_iter()
            .filter(|clip_id| {
                self.project.timelines[timeline_index]
                    .clip_location(clip_id)
                    .is_some_and(|location| {
                        self.project.timelines[timeline_index].tracks[location.track_index].clips
                            [location.clip_index]
                            .link_group_id
                            .is_some()
                    })
            })
            .collect::<Vec<_>>();
        self.transact(MutationKind::UnlinkClips, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let mut changes = MutationChanges::default();
            for clip_id in targets {
                let location = session.clip_location(timeline_index, &clip_id)?;
                let track =
                    &mut session.project.timelines[timeline_index].tracks[location.track_index];
                track.clips[location.clip_index].link_group_id = None;
                changes.updated_clip_ids.push(clip_id);
                changes.affected_track_ids.push(track.id.clone());
            }
            Ok(TransactionResult::new(changes))
        })
    }

    pub fn add_track(
        &mut self,
        timeline_id: &str,
        track_type: ClipType,
        requested_index: usize,
    ) -> Result<MutationReceipt, MutationError> {
        self.timeline_index(timeline_id)?;
        self.transact(MutationKind::AddTrack, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let tracks = &session.project.timelines[timeline_index].tracks;
            let first_audio = tracks
                .iter()
                .position(|track| track.track_type == ClipType::Audio)
                .unwrap_or(tracks.len());
            let bounded = requested_index.min(tracks.len());
            let insertion = if track_type == ClipType::Audio {
                bounded.max(first_audio)
            } else {
                bounded.min(first_audio)
            };
            let track = Track::new(track_type);
            let id = track.id.clone();
            session.project.timelines[timeline_index]
                .tracks
                .insert(insertion, track);
            let mut result = TransactionResult::new(MutationChanges {
                created_track_ids: vec![id],
                ..MutationChanges::default()
            });
            result
                .details
                .insert("trackIndex".to_owned(), json!(insertion));
            Ok(result)
        })
    }

    pub fn remove_tracks(
        &mut self,
        timeline_id: &str,
        track_ids: &[String],
    ) -> Result<MutationReceipt, MutationError> {
        let timeline_index = self.timeline_index(timeline_id)?;
        ensure_unique_ids(track_ids, "track")?;
        for track_id in track_ids {
            self.track_index(timeline_index, track_id)?;
        }
        let ids: HashSet<_> = track_ids.iter().cloned().collect();
        self.transact(MutationKind::RemoveTracks, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let removed_clip_ids = session.project.timelines[timeline_index]
                .tracks
                .iter()
                .filter(|track| ids.contains(&track.id))
                .flat_map(|track| track.clips.iter().map(|clip| clip.id.clone()))
                .collect();
            session.project.timelines[timeline_index]
                .tracks
                .retain(|track| !ids.contains(&track.id));
            Ok(TransactionResult::new(MutationChanges {
                removed_track_ids: ids.into_iter().collect(),
                removed_clip_ids,
                ..MutationChanges::default()
            }))
        })
    }

    pub fn reorder_track(
        &mut self,
        timeline_id: &str,
        track_id: &str,
        target_index: usize,
    ) -> Result<MutationReceipt, MutationError> {
        let timeline_index = self.timeline_index(timeline_id)?;
        self.track_index(timeline_index, track_id)?;
        self.transact(MutationKind::ReorderTrack, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let from = session.track_index(timeline_index, track_id)?;
            let tracks = &session.project.timelines[timeline_index].tracks;
            let first_audio = tracks
                .iter()
                .position(|track| track.track_type == ClipType::Audio)
                .unwrap_or(tracks.len());
            let is_audio = tracks[from].track_type == ClipType::Audio;
            let (lower, upper) = if is_audio {
                (first_audio, tracks.len().saturating_sub(1))
            } else {
                (0, first_audio.saturating_sub(1))
            };
            let destination = target_index.clamp(lower, upper);
            if destination != from {
                let track = session.project.timelines[timeline_index]
                    .tracks
                    .remove(from);
                session.project.timelines[timeline_index]
                    .tracks
                    .insert(destination, track);
            }
            let mut result = TransactionResult::new(MutationChanges {
                affected_track_ids: vec![track_id.to_owned()],
                ..MutationChanges::default()
            });
            result
                .details
                .insert("trackIndex".to_owned(), json!(destination));
            Ok(result)
        })
    }

    pub fn update_track(
        &mut self,
        timeline_id: &str,
        track_id: &str,
        patch: TrackPatch,
    ) -> Result<MutationReceipt, MutationError> {
        let timeline_index = self.timeline_index(timeline_id)?;
        self.track_index(timeline_index, track_id)?;
        if let Some(height) = patch.display_height
            && !height.is_finite()
        {
            return Err(MutationError::new(
                MutationErrorCode::InvalidArgument,
                "displayHeight must be finite",
            ));
        }
        self.transact(MutationKind::UpdateTrack, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let track_index = session.track_index(timeline_index, track_id)?;
            let track = &mut session.project.timelines[timeline_index].tracks[track_index];
            if let Some(value) = patch.muted {
                track.muted = value;
            }
            if let Some(value) = patch.hidden {
                track.hidden = value;
            }
            if let Some(value) = patch.sync_locked {
                if !value
                    && track
                        .clips
                        .iter()
                        .any(|clip| clip.multicam_group_id.is_some())
                {
                    return Err(MutationError::new(
                        MutationErrorCode::MulticamAtomicity,
                        "a multicam track must remain sync locked",
                    ));
                }
                track.sync_locked = value;
            }
            if let Some(value) = patch.display_height {
                track.display_height = value.clamp(32.0, 200.0);
            }
            Ok(TransactionResult::new(MutationChanges {
                affected_track_ids: vec![track_id.to_owned()],
                ..MutationChanges::default()
            }))
        })
    }

    pub fn upsert_keyframe(
        &mut self,
        timeline_id: &str,
        clip_id: &str,
        property: AnimatableProperty,
        frame: Frame,
        value: KeyframeValue,
    ) -> Result<MutationReceipt, MutationError> {
        let timeline_index = self.timeline_index(timeline_id)?;
        let location = self.clip_location(timeline_index, clip_id)?;
        validate_keyframe_frame(
            &self.project.timelines[timeline_index].tracks[location.track_index].clips
                [location.clip_index],
            frame,
        )?;
        validate_keyframe_value(property, &value)?;
        self.transact(MutationKind::UpsertKeyframe, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let location = session.clip_location(timeline_index, clip_id)?;
            let track = &mut session.project.timelines[timeline_index].tracks[location.track_index];
            let clip = &mut track.clips[location.clip_index];
            let offset = frame - clip.start_frame;
            match (property, value) {
                (AnimatableProperty::Opacity, KeyframeValue::Number(value)) => {
                    upsert_track(&mut clip.opacity_track, offset, value)
                }
                (AnimatableProperty::Position, KeyframeValue::Pair(value)) => {
                    upsert_track(&mut clip.position_track, offset, value)
                }
                (AnimatableProperty::Scale, KeyframeValue::Pair(value)) => {
                    upsert_track(&mut clip.scale_track, offset, value)
                }
                (AnimatableProperty::Rotation, KeyframeValue::Number(value)) => {
                    upsert_track(&mut clip.rotation_track, offset, value)
                }
                (AnimatableProperty::Crop, KeyframeValue::Crop(value)) => {
                    upsert_track(&mut clip.crop_track, offset, value)
                }
                (AnimatableProperty::Volume, KeyframeValue::Number(value)) => {
                    upsert_track(&mut clip.volume_track, offset, value)
                }
                _ => unreachable!("value was validated before mutation"),
            }
            Ok(TransactionResult::new(MutationChanges {
                updated_clip_ids: vec![clip_id.to_owned()],
                affected_track_ids: vec![track.id.clone()],
                ..MutationChanges::default()
            }))
        })
    }

    pub fn remove_keyframe(
        &mut self,
        timeline_id: &str,
        clip_id: &str,
        property: AnimatableProperty,
        frame: Frame,
    ) -> Result<MutationReceipt, MutationError> {
        let timeline_index = self.timeline_index(timeline_id)?;
        self.clip_location(timeline_index, clip_id)?;
        self.transact(MutationKind::RemoveKeyframe, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let location = session.clip_location(timeline_index, clip_id)?;
            let track = &mut session.project.timelines[timeline_index].tracks[location.track_index];
            let clip = &mut track.clips[location.clip_index];
            let offset = frame - clip.start_frame;
            match property {
                AnimatableProperty::Opacity => remove_from_track(&mut clip.opacity_track, offset),
                AnimatableProperty::Position => remove_from_track(&mut clip.position_track, offset),
                AnimatableProperty::Scale => remove_from_track(&mut clip.scale_track, offset),
                AnimatableProperty::Rotation => remove_from_track(&mut clip.rotation_track, offset),
                AnimatableProperty::Crop => remove_from_track(&mut clip.crop_track, offset),
                AnimatableProperty::Volume => remove_from_track(&mut clip.volume_track, offset),
            }
            Ok(TransactionResult::new(MutationChanges {
                updated_clip_ids: vec![clip_id.to_owned()],
                affected_track_ids: vec![track.id.clone()],
                ..MutationChanges::default()
            }))
        })
    }

    pub fn move_keyframe(
        &mut self,
        timeline_id: &str,
        clip_id: &str,
        property: AnimatableProperty,
        from_frame: Frame,
        to_frame: Frame,
    ) -> Result<MutationReceipt, MutationError> {
        let timeline_index = self.timeline_index(timeline_id)?;
        let location = self.clip_location(timeline_index, clip_id)?;
        validate_keyframe_frame(
            &self.project.timelines[timeline_index].tracks[location.track_index].clips
                [location.clip_index],
            to_frame,
        )?;
        self.transact(MutationKind::MoveKeyframe, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let location = session.clip_location(timeline_index, clip_id)?;
            let track = &mut session.project.timelines[timeline_index].tracks[location.track_index];
            let clip = &mut track.clips[location.clip_index];
            let from = from_frame - clip.start_frame;
            let to = to_frame - clip.start_frame;
            match property {
                AnimatableProperty::Opacity => move_in_track(&mut clip.opacity_track, from, to),
                AnimatableProperty::Position => move_in_track(&mut clip.position_track, from, to),
                AnimatableProperty::Scale => move_in_track(&mut clip.scale_track, from, to),
                AnimatableProperty::Rotation => move_in_track(&mut clip.rotation_track, from, to),
                AnimatableProperty::Crop => move_in_track(&mut clip.crop_track, from, to),
                AnimatableProperty::Volume => move_in_track(&mut clip.volume_track, from, to),
            };
            Ok(TransactionResult::new(MutationChanges {
                updated_clip_ids: vec![clip_id.to_owned()],
                affected_track_ids: vec![track.id.clone()],
                ..MutationChanges::default()
            }))
        })
    }

    pub fn set_keyframe_interpolation(
        &mut self,
        timeline_id: &str,
        clip_id: &str,
        property: AnimatableProperty,
        frame: Frame,
        interpolation: Interpolation,
    ) -> Result<MutationReceipt, MutationError> {
        let timeline_index = self.timeline_index(timeline_id)?;
        self.clip_location(timeline_index, clip_id)?;
        self.transact(
            MutationKind::SetKeyframeInterpolation,
            timeline_id,
            move |session| {
                let timeline_index = session.timeline_index(timeline_id)?;
                let location = session.clip_location(timeline_index, clip_id)?;
                let track =
                    &mut session.project.timelines[timeline_index].tracks[location.track_index];
                let clip = &mut track.clips[location.clip_index];
                let offset = frame - clip.start_frame;
                match property {
                    AnimatableProperty::Opacity => {
                        set_track_interpolation(&mut clip.opacity_track, offset, interpolation)
                    }
                    AnimatableProperty::Position => {
                        set_track_interpolation(&mut clip.position_track, offset, interpolation)
                    }
                    AnimatableProperty::Scale => {
                        set_track_interpolation(&mut clip.scale_track, offset, interpolation)
                    }
                    AnimatableProperty::Rotation => {
                        set_track_interpolation(&mut clip.rotation_track, offset, interpolation)
                    }
                    AnimatableProperty::Crop => {
                        set_track_interpolation(&mut clip.crop_track, offset, interpolation)
                    }
                    AnimatableProperty::Volume => {
                        set_track_interpolation(&mut clip.volume_track, offset, interpolation)
                    }
                }
                Ok(TransactionResult::new(MutationChanges {
                    updated_clip_ids: vec![clip_id.to_owned()],
                    affected_track_ids: vec![track.id.clone()],
                    ..MutationChanges::default()
                }))
            },
        )
    }

    pub fn copy_clips(
        &mut self,
        timeline_id: &str,
        clip_ids: &[String],
    ) -> Result<CopyReceipt, MutationError> {
        let timeline_index = self.timeline_index(timeline_id)?;
        if clip_ids.is_empty() {
            return Ok(CopyReceipt {
                copied_clip_ids: Vec::new(),
                entry_count: self.clipboard.len(),
                skipped_ids: Vec::new(),
            });
        }
        let requested: HashSet<_> = clip_ids.iter().cloned().collect();
        let mut captures = Vec::new();
        let mut found = HashSet::new();
        for (track_index, track) in self.project.timelines[timeline_index]
            .tracks
            .iter()
            .enumerate()
        {
            for clip in &track.clips {
                if requested.contains(&clip.id) {
                    found.insert(clip.id.clone());
                    captures.push((
                        clip.clone(),
                        track_index,
                        track.id.clone(),
                        track.track_type,
                    ));
                }
            }
        }
        captures.sort_by(|left, right| {
            (left.1, left.0.start_frame, left.0.id.as_str()).cmp(&(
                right.1,
                right.0.start_frame,
                right.0.id.as_str(),
            ))
        });
        let skipped_ids = requested.difference(&found).cloned().collect::<Vec<_>>();
        if !captures.is_empty() {
            let minimum_track = captures[0].1;
            let minimum_start = captures
                .iter()
                .map(|capture| capture.0.start_frame)
                .min()
                .unwrap_or(0);
            self.clipboard = captures
                .into_iter()
                .map(
                    |(clip, track_index, source_track_id, source_track_type)| ClipClipboardEntry {
                        frame_offset: clip.start_frame - minimum_start,
                        track_offset: (track_index - minimum_track) as i64,
                        clip,
                        source_track_id,
                        source_track_type,
                    },
                )
                .collect();
        }
        Ok(CopyReceipt {
            copied_clip_ids: found.into_iter().collect(),
            entry_count: self.clipboard.len(),
            skipped_ids,
        })
    }

    pub fn paste_clips(
        &mut self,
        timeline_id: &str,
        track_id: &str,
        start_frame: Frame,
    ) -> Result<MutationReceipt, MutationError> {
        if start_frame < 0 {
            return Err(invalid_frame("startFrame must not be negative"));
        }
        let timeline_index = self.timeline_index(timeline_id)?;
        let base_track = self.track_index(timeline_index, track_id)?;
        let clipboard = self.clipboard.clone();
        self.transact(MutationKind::PasteClips, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let mut placements = Vec::new();
            let mut skipped_ids = Vec::new();
            let mut warnings = Vec::new();
            for entry in &clipboard {
                let destination = base_track as i64 + entry.track_offset;
                if destination < 0
                    || destination as usize
                        >= session.project.timelines[timeline_index].tracks.len()
                {
                    skipped_ids.push(entry.clip.id.clone());
                    warnings.push(format!(
                        "clip {} has no destination track at its copied offset",
                        entry.clip.id
                    ));
                    continue;
                }
                let destination = destination as usize;
                let destination_type =
                    session.project.timelines[timeline_index].tracks[destination].track_type;
                if !destination_type.is_compatible_with(entry.clip.media_type) {
                    skipped_ids.push(entry.clip.id.clone());
                    warnings.push(format!(
                        "clip {} is incompatible with its destination track",
                        entry.clip.id
                    ));
                    continue;
                }
                if entry.clip.source_clip_type == ClipType::Sequence
                    && would_create_nest_cycle(&session.project, &entry.clip.media_ref, timeline_id)
                {
                    skipped_ids.push(entry.clip.id.clone());
                    warnings.push(format!(
                        "clip {} would create a nesting cycle",
                        entry.clip.id
                    ));
                    continue;
                }
                let destination_start =
                    checked_add(start_frame, entry.frame_offset).map_err(frame_error)?;
                checked_add(destination_start, entry.clip.duration_frames).map_err(frame_error)?;
                placements.push((entry.clone(), destination, destination_start));
            }

            let mut changes = MutationChanges {
                skipped_ids,
                warnings,
                ..MutationChanges::default()
            };
            for (entry, destination, destination_start) in &placements {
                let report = OverwriteEngine::clear_region(
                    &mut session.project.timelines[timeline_index].tracks[*destination].clips,
                    FrameRange {
                        start: *destination_start,
                        end: *destination_start + entry.clip.duration_frames,
                    },
                    &[],
                )
                .map_err(split_error)?;
                append_overwrite_changes(&mut changes, report);
            }

            let mut group_counts = HashMap::<String, usize>::new();
            for (entry, _, _) in &placements {
                if let Some(group) = &entry.clip.link_group_id {
                    *group_counts.entry(group.clone()).or_default() += 1;
                }
            }
            let mut groups = HashMap::new();
            for (entry, destination, destination_start) in placements {
                let old_group = entry.clip.link_group_id.clone();
                let mut clone = entry.clip;
                clone.start_frame = destination_start;
                clone.freshen_ids(&mut groups);
                clone.multicam_group_id = None;
                if old_group
                    .as_ref()
                    .is_some_and(|group| group_counts.get(group).copied().unwrap_or(0) <= 1)
                {
                    clone.link_group_id = None;
                }
                changes.created_clip_ids.push(clone.id.clone());
                changes.affected_track_ids.push(
                    session.project.timelines[timeline_index].tracks[destination]
                        .id
                        .clone(),
                );
                session.project.timelines[timeline_index].tracks[destination]
                    .clips
                    .push(clone);
            }
            for track in &mut session.project.timelines[timeline_index].tracks {
                track.sort_clips();
            }
            Ok(TransactionResult::new(changes))
        })
    }

    pub fn apply_project_settings(
        &mut self,
        timeline_id: &str,
        fps: i32,
        width: i32,
        height: i32,
    ) -> Result<MutationReceipt, MutationError> {
        if fps <= 0 || fps > 1_000 {
            return Err(MutationError::new(
                MutationErrorCode::InvalidArgument,
                "fps must be between 1 and 1000",
            ));
        }
        if width <= 0 || height <= 0 || width > 65_536 || height > 65_536 {
            return Err(MutationError::new(
                MutationErrorCode::InvalidArgument,
                "width and height must be between 1 and 65536",
            ));
        }
        self.timeline_index(timeline_id)?;
        self.transact(
            MutationKind::ChangeProjectSettings,
            timeline_id,
            move |session| {
                let active_index = session.timeline_index(timeline_id)?;
                let previous_fps = session.project.timelines[active_index].fps;
                let previous_width = session.project.timelines[active_index].width;
                let previous_height = session.project.timelines[active_index].height;
                let source_dimensions =
                    source_dimensions(&session.project, &session.media_manifest);
                let mut changes = MutationChanges::default();

                if fps != previous_fps && previous_fps > 0 {
                    let scale = f64::from(fps) / f64::from(previous_fps);
                    for timeline in &mut session.project.timelines {
                        rescale_timeline(timeline, scale)?;
                        changes
                            .affected_track_ids
                            .extend(timeline.tracks.iter().map(|track| track.id.clone()));
                        changes.updated_clip_ids.extend(
                            timeline
                                .tracks
                                .iter()
                                .flat_map(|track| track.clips.iter().map(|clip| clip.id.clone())),
                        );
                    }
                    if let Some(view_states) = &mut session.project.view_states {
                        for view_state in view_states.values_mut() {
                            view_state.playhead_frame =
                                swift_round(view_state.playhead_frame as f64 * scale)
                                    .map_err(frame_error)?;
                        }
                    }
                }

                if width != previous_width || height != previous_height {
                    let timeline = &mut session.project.timelines[active_index];
                    for track in &mut timeline.tracks {
                        for clip in &mut track.clips {
                            let Some((source_width, source_height)) =
                                source_dimensions.get(&clip.media_ref).copied()
                            else {
                                continue;
                            };
                            if previous_width <= 0 || previous_height <= 0 {
                                continue;
                            }
                            let source_aspect = f64::from(source_width) / f64::from(source_height);
                            let old_aspect = source_aspect
                                / (f64::from(previous_width) / f64::from(previous_height));
                            let new_aspect = source_aspect / (f64::from(width) / f64::from(height));
                            let old_fit = fit_transform(
                                source_width,
                                source_height,
                                previous_width,
                                previous_height,
                            );
                            let scale_animated = clip
                                .scale_track
                                .as_ref()
                                .is_some_and(KeyframeTrack::is_active);
                            if !scale_animated && transform_scale_matches(clip.transform, old_fit) {
                                let new_fit =
                                    fit_transform(source_width, source_height, width, height);
                                clip.transform.width = new_fit.width;
                                clip.transform.height = new_fit.height;
                            } else {
                                let height_scale = old_aspect / new_aspect;
                                clip.transform.height *= height_scale;
                                if let Some(track) = &mut clip.scale_track
                                    && track.is_active()
                                {
                                    for keyframe in &mut track.keyframes {
                                        keyframe.value.b *= height_scale;
                                    }
                                }
                            }
                            changes.updated_clip_ids.push(clip.id.clone());
                            changes.affected_track_ids.push(track.id.clone());
                        }
                    }
                }

                for timeline in &mut session.project.timelines {
                    timeline.fps = fps;
                    timeline.settings_configured = true;
                }
                session.project.timelines[active_index].width = width;
                session.project.timelines[active_index].height = height;
                let mut result = TransactionResult::new(changes);
                result.details.insert(
                    "previous".to_owned(),
                    json!({"fps":previous_fps,"width":previous_width,"height":previous_height}),
                );
                result.details.insert(
                    "current".to_owned(),
                    json!({"fps":fps,"width":width,"height":height}),
                );
                Ok(result)
            },
        )
    }

    pub fn update_clips(
        &mut self,
        timeline_id: &str,
        clips: Vec<Clip>,
    ) -> Result<MutationReceipt, MutationError> {
        if clips.is_empty() {
            return self.no_op_receipt(MutationKind::UpdateClips, timeline_id);
        }
        let timeline_index = self.timeline_index(timeline_id)?;
        let mut seen = HashSet::new();
        for clip in &clips {
            if !seen.insert(clip.id.clone()) {
                return Err(MutationError::new(
                    MutationErrorCode::DuplicateId,
                    format!("duplicate clip update: {}", clip.id),
                ));
            }
            validate_clip_for_mutation(clip)?;
            self.clip_location(timeline_index, &clip.id)?;
        }
        self.transact(MutationKind::UpdateClips, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let replacements = clips
                .into_iter()
                .map(|clip| (clip.id.clone(), clip))
                .collect::<HashMap<_, _>>();
            let mut changes = MutationChanges::default();
            for track in &mut session.project.timelines[timeline_index].tracks {
                for clip in &mut track.clips {
                    let Some(replacement) = replacements.get(&clip.id) else {
                        continue;
                    };
                    if !track.track_type.is_compatible_with(replacement.media_type) {
                        return Err(MutationError::new(
                            MutationErrorCode::IncompatibleTrack,
                            format!(
                                "clip {} is incompatible with track {}",
                                replacement.id, track.id
                            ),
                        ));
                    }
                    let mut next = replacement.clone();
                    next.clamp_keyframes_to_duration();
                    next.clamp_fades_to_duration();
                    *clip = next;
                    changes.updated_clip_ids.push(clip.id.clone());
                    changes.affected_track_ids.push(track.id.clone());
                }
                track.sort_clips();
                validate_track_collisions(track)?;
            }
            validate_project(&session.project)?;
            Ok(TransactionResult::new(changes))
        })
    }

    pub fn set_clip_speed(
        &mut self,
        timeline_id: &str,
        clip_ids: &[String],
        speed: f64,
        ripple: bool,
    ) -> Result<MutationReceipt, MutationError> {
        if clip_ids.is_empty() {
            return self.no_op_receipt(MutationKind::SetClipSpeed, timeline_id);
        }
        if !speed.is_finite() || speed <= 0.0 {
            return Err(MutationError::new(
                MutationErrorCode::InvalidArgument,
                "clip speed must be finite and greater than zero",
            ));
        }
        ensure_unique_ids(clip_ids, "clip")?;
        let timeline_index = self.timeline_index(timeline_id)?;
        for clip_id in clip_ids {
            let location = self.clip_location(timeline_index, clip_id)?;
            let clip = &self.project.timelines[timeline_index].tracks[location.track_index].clips
                [location.clip_index];
            if clip.multicam_group_id.is_some() {
                return Err(MutationError::new(
                    MutationErrorCode::MulticamAtomicity,
                    "can't change speed on a multicam clip",
                ));
            }
            if !clip.supports_retiming() {
                return Err(MutationError::new(
                    MutationErrorCode::InvalidArgument,
                    format!("clip {clip_id} does not support retiming"),
                ));
            }
        }
        let ids = clip_ids.to_vec();
        self.transact(MutationKind::SetClipSpeed, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let mut changes = MutationChanges::default();
            for clip_id in &ids {
                let location = session.clip_location(timeline_index, clip_id)?;
                let track = &mut session.project.timelines[timeline_index].tracks
                    [location.track_index];
                let clip = &mut track.clips[location.clip_index];
                if (clip.speed - speed).abs() < f64::EPSILON {
                    continue;
                }
                let clip_id = clip.id.clone();
                let track_id = track.id.clone();
                let old_duration = clip.duration_frames;
                let old_end = clip.end_frame();
                let start_frame = clip.start_frame;
                let new_duration = retimed_duration_frames(old_duration, clip.speed, speed)?;
                clip.speed = speed;
                clip.duration_frames = new_duration;
                if old_duration > 0 {
                    clip.rescale_keyframes(new_duration as f64 / old_duration as f64)
                        .map_err(frame_error)?;
                }
                clip.clamp_keyframes_to_duration();
                clip.clamp_fades_to_duration();
                changes.updated_clip_ids.push(clip_id.clone());
                changes.affected_track_ids.push(track_id);

                if ripple {
                    let ripple_delta = checked_sub(start_frame + new_duration, old_end)
                        .map_err(frame_error)?;
                    if ripple_delta != 0 {
                        let chain = track.contiguous_clip_ids(old_end, &clip_id);
                        for other in &mut track.clips {
                            if chain.contains(&other.id) {
                                other.start_frame =
                                    checked_add(other.start_frame, ripple_delta)
                                        .map_err(frame_error)?;
                                changes.updated_clip_ids.push(other.id.clone());
                            }
                        }
                    }
                }
                track.sort_clips();
                validate_track_collisions(track)?;
            }
            validate_project(&session.project)?;
            Ok(TransactionResult::new(changes))
        })
    }

    pub fn set_clip_fades(
        &mut self,
        timeline_id: &str,
        clip_id: &str,
        fade_in_frames: Option<Frame>,
        fade_out_frames: Option<Frame>,
    ) -> Result<MutationReceipt, MutationError> {
        if fade_in_frames.is_none() && fade_out_frames.is_none() {
            return self.no_op_receipt(MutationKind::SetClipFades, timeline_id);
        }
        let timeline_index = self.timeline_index(timeline_id)?;
        self.clip_location(timeline_index, clip_id)?;
        if fade_in_frames.is_some_and(|value| value < 0)
            || fade_out_frames.is_some_and(|value| value < 0)
        {
            return Err(MutationError::new(
                MutationErrorCode::InvalidArgument,
                "fade frames must be non-negative",
            ));
        }
        let clip_id = clip_id.to_owned();
        self.transact(MutationKind::SetClipFades, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let location = session.clip_location(timeline_index, &clip_id)?;
            let track =
                &mut session.project.timelines[timeline_index].tracks[location.track_index];
            let clip = &mut track.clips[location.clip_index];
            if let Some(value) = fade_in_frames {
                clip.fade_in_frames = value;
            }
            if let Some(value) = fade_out_frames {
                clip.fade_out_frames = value;
            }
            clip.clamp_fades_to_duration();
            Ok(TransactionResult::new(MutationChanges {
                updated_clip_ids: vec![clip.id.clone()],
                affected_track_ids: vec![track.id.clone()],
                ..MutationChanges::default()
            }))
        })
    }

    pub fn slip_clips(
        &mut self,
        timeline_id: &str,
        clip_id: &str,
        delta_frames: Frame,
        propagate_to_linked: bool,
    ) -> Result<MutationReceipt, MutationError> {
        let timeline_index = self.timeline_index(timeline_id)?;
        let lead_location = self.clip_location(timeline_index, clip_id)?;
        let lead = self.project.timelines[timeline_index].tracks[lead_location.track_index].clips
            [lead_location.clip_index]
            .clone();
        if !is_slip_eligible(&lead) {
            return Err(MutationError::new(
                MutationErrorCode::InvalidArgument,
                "clip is not eligible for slip",
            ));
        }

        let mut targets = vec![lead.clone()];
        if propagate_to_linked {
            for partner_id in linked_partner_ids(&self.project.timelines[timeline_index], clip_id) {
                if partner_id == clip_id {
                    continue;
                }
                let Ok(location) = self.clip_location(timeline_index, &partner_id) else {
                    continue;
                };
                let partner = &self.project.timelines[timeline_index].tracks[location.track_index]
                    .clips[location.clip_index];
                if is_slip_eligible(partner) {
                    targets.push(partner.clone());
                }
            }
        }

        let mut delta = delta_frames;
        for target in &targets {
            let speed = target.speed.max(0.001);
            let right = ((target.trim_start_frame as f64) / speed).floor() as Frame;
            let left = ((effective_trim_end(&self.project, target) as f64) / speed).floor() as Frame;
            delta = delta.min(right).max(-left);
        }
        if delta == 0 {
            return self.no_op_receipt(MutationKind::SlipClips, timeline_id);
        }

        let applied: HashMap<String, Frame> = targets
            .iter()
            .map(|target| {
                let source_delta = swift_round(delta as f64 * target.speed).unwrap_or(0);
                let trim_end = effective_trim_end(&self.project, target);
                let applied = source_delta.min(target.trim_start_frame).max(-trim_end);
                (target.id.clone(), applied)
            })
            .collect();
        if applied.values().all(|value| *value == 0) {
            return self.no_op_receipt(MutationKind::SlipClips, timeline_id);
        }

        self.transact(MutationKind::SlipClips, timeline_id, move |session| {
            let timeline_index = session.timeline_index(timeline_id)?;
            let mut changes = MutationChanges::default();
            for track in &mut session.project.timelines[timeline_index].tracks {
                for clip in &mut track.clips {
                    let Some(applied_delta) = applied.get(&clip.id).copied() else {
                        continue;
                    };
                    if applied_delta == 0 {
                        continue;
                    }
                    clip.trim_start_frame = checked_sub(clip.trim_start_frame, applied_delta)
                        .map_err(frame_error)?;
                    clip.trim_end_frame =
                        checked_add(clip.trim_end_frame, applied_delta).map_err(frame_error)?;
                    changes.updated_clip_ids.push(clip.id.clone());
                    changes.affected_track_ids.push(track.id.clone());
                }
            }
            validate_project(&session.project)?;
            Ok(TransactionResult::new(changes))
        })
    }

    pub fn create_timeline(
        &mut self,
        timeline: Timeline,
        make_active: bool,
    ) -> Result<MutationReceipt, MutationError> {
        let timeline_id = timeline.id.clone();
        let receipt_timeline_id = timeline_id.clone();
        let mut candidate = self.project.clone();
        candidate.timelines.push(timeline.clone());
        validate_project(&candidate)?;
        self.transact(
            MutationKind::CreateTimeline,
            &receipt_timeline_id,
            move |session| {
                let mut changes = MutationChanges::default();
                changes
                    .created_track_ids
                    .extend(timeline.tracks.iter().map(|track| track.id.clone()));
                changes.created_clip_ids.extend(
                    timeline
                        .tracks
                        .iter()
                        .flat_map(|track| track.clips.iter().map(|clip| clip.id.clone())),
                );
                session.project.timelines.push(timeline);
                if make_active {
                    session.project.active_timeline_id = Some(timeline_id.clone());
                    let open = session.project.open_timeline_ids.get_or_insert_default();
                    if !open.contains(&timeline_id) {
                        open.push(timeline_id.clone());
                    }
                }
                let mut result = TransactionResult::new(changes);
                result
                    .details
                    .insert("timelineId".into(), json!(timeline_id));
                Ok(result)
            },
        )
    }

    pub fn set_active_timeline(
        &mut self,
        timeline_id: &str,
    ) -> Result<MutationReceipt, MutationError> {
        self.timeline_index(timeline_id)?;
        self.transact(
            MutationKind::SetActiveTimeline,
            timeline_id,
            |session| {
                session.project.active_timeline_id = Some(timeline_id.to_owned());
                let open = session.project.open_timeline_ids.get_or_insert_default();
                if !open.iter().any(|id| id == timeline_id) {
                    open.push(timeline_id.to_owned());
                }
                let mut result = TransactionResult::new(MutationChanges::default());
                result
                    .details
                    .insert("timelineId".into(), json!(timeline_id));
                Ok(result)
            },
        )
    }

    pub fn update_media_manifest(
        &mut self,
        timeline_id: &str,
        media_manifest: MediaManifest,
    ) -> Result<MutationReceipt, MutationError> {
        self.timeline_index(timeline_id)?;
        let mut ids = HashSet::new();
        if media_manifest
            .entries
            .iter()
            .any(|entry| entry.id.is_empty() || !ids.insert(entry.id.clone()))
        {
            return Err(MutationError::new(
                MutationErrorCode::DuplicateId,
                "media manifest has an empty or duplicate id",
            ));
        }
        self.transact(
            MutationKind::UpdateMediaManifest,
            timeline_id,
            move |session| {
                session.media_manifest = media_manifest;
                Ok(TransactionResult::new(MutationChanges::default()))
            },
        )
    }

    pub fn execute_batch(
        &mut self,
        timeline_id: &str,
        commands: Vec<EditorCommand>,
    ) -> Result<MutationReceipt, MutationError> {
        if commands.is_empty() {
            return self.no_op_receipt(MutationKind::Batch, timeline_id);
        }
        if commands.iter().any(|command| {
            matches!(
                command,
                EditorCommand::Undo | EditorCommand::Redo | EditorCommand::Batch { .. }
            )
        }) {
            return Err(MutationError::new(
                MutationErrorCode::InvalidArgument,
                "batch commands cannot contain undo, redo, or another batch",
            ));
        }
        self.timeline_index(timeline_id)?;
        self.transact(MutationKind::Batch, timeline_id, move |session| {
            let mut staged = EditorSession::with_manifest(
                session.project.clone(),
                session.media_manifest.clone(),
            )?;
            let mut changes = MutationChanges::default();
            let mut receipts = Vec::with_capacity(commands.len());
            for command in commands {
                let receipt = staged.execute(command)?;
                changes.created_clip_ids.extend(receipt.created_clip_ids.clone());
                changes.updated_clip_ids.extend(receipt.updated_clip_ids.clone());
                changes.removed_clip_ids.extend(receipt.removed_clip_ids.clone());
                changes.affected_track_ids.extend(receipt.affected_track_ids.clone());
                changes.created_track_ids.extend(receipt.created_track_ids.clone());
                changes.removed_track_ids.extend(receipt.removed_track_ids.clone());
                changes.skipped_ids.extend(receipt.skipped_ids.clone());
                changes.warnings.extend(receipt.warnings.clone());
                receipts.push(receipt);
            }
            let snapshot = staged.snapshot();
            session.project = snapshot.project;
            session.media_manifest = snapshot.media_manifest;
            let mut result = TransactionResult::new(changes);
            result
                .details
                .insert("receipts".into(), json!(receipts));
            Ok(result)
        })
    }

    pub fn undo(&mut self) -> Result<MutationReceipt, MutationError> {
        if self.revision == u64::MAX {
            return Err(MutationError::new(
                MutationErrorCode::ArithmeticOverflow,
                "revision overflowed",
            ));
        }
        let Some(entry) = self.undo_stack.pop() else {
            return Err(MutationError::new(
                MutationErrorCode::NoUndo,
                "there is no edit to undo",
            ));
        };
        let revision_before = self.revision;
        self.project = entry.before.project.clone();
        self.media_manifest = entry.before.media_manifest.clone();
        self.revision = self.revision.checked_add(1).ok_or_else(|| {
            MutationError::new(MutationErrorCode::ArithmeticOverflow, "revision overflowed")
        })?;
        let mut inverse = MutationChanges {
            created_clip_ids: entry.changes.removed_clip_ids.clone(),
            removed_clip_ids: entry.changes.created_clip_ids.clone(),
            updated_clip_ids: entry.changes.updated_clip_ids.clone(),
            affected_track_ids: entry.changes.affected_track_ids.clone(),
            created_track_ids: entry.changes.removed_track_ids.clone(),
            removed_track_ids: entry.changes.created_track_ids.clone(),
            ..MutationChanges::default()
        };
        inverse.normalize();
        self.redo_stack.push(entry.clone());
        Ok(receipt(
            MutationKind::Undo,
            MutationStatus::Undone,
            revision_before,
            self.revision,
            entry.timeline_id,
            inverse,
            BTreeMap::from([("originalAction".to_owned(), json!(entry.action))]),
        ))
    }

    pub fn redo(&mut self) -> Result<MutationReceipt, MutationError> {
        if self.revision == u64::MAX {
            return Err(MutationError::new(
                MutationErrorCode::ArithmeticOverflow,
                "revision overflowed",
            ));
        }
        let Some(entry) = self.redo_stack.pop() else {
            return Err(MutationError::new(
                MutationErrorCode::NoRedo,
                "there is no edit to redo",
            ));
        };
        let revision_before = self.revision;
        self.project = entry.after.project.clone();
        self.media_manifest = entry.after.media_manifest.clone();
        self.revision = self.revision.checked_add(1).ok_or_else(|| {
            MutationError::new(MutationErrorCode::ArithmeticOverflow, "revision overflowed")
        })?;
        self.undo_stack.push(entry.clone());
        Ok(receipt(
            MutationKind::Redo,
            MutationStatus::Redone,
            revision_before,
            self.revision,
            entry.timeline_id,
            entry.changes,
            BTreeMap::from([("originalAction".to_owned(), json!(entry.action))]),
        ))
    }

    fn transact<F>(
        &mut self,
        action: MutationKind,
        timeline_id: &str,
        operation: F,
    ) -> Result<MutationReceipt, MutationError>
    where
        F: FnOnce(&mut Self) -> Result<TransactionResult, MutationError>,
    {
        if self.revision == u64::MAX {
            return Err(MutationError::new(
                MutationErrorCode::ArithmeticOverflow,
                "revision overflowed",
            ));
        }
        let before = self.snapshot();
        let revision_before = self.revision;
        let result = match operation(self) {
            Ok(result) => result,
            Err(error) => {
                self.project = before.project;
                self.media_manifest = before.media_manifest;
                return Err(error);
            }
        };
        let after = self.snapshot();
        let mut changes = result.changes;
        changes.normalize();
        if before == after {
            return Ok(receipt(
                action,
                MutationStatus::NoOp,
                revision_before,
                revision_before,
                timeline_id.to_owned(),
                changes,
                result.details,
            ));
        }
        self.revision = self.revision.checked_add(1).ok_or_else(|| {
            MutationError::new(MutationErrorCode::ArithmeticOverflow, "revision overflowed")
        })?;
        self.undo_stack.push(HistoryEntry {
            action,
            timeline_id: timeline_id.to_owned(),
            before,
            after,
            changes: changes.clone(),
        });
        if self.undo_stack.len() > HISTORY_LIMIT {
            self.undo_stack.remove(0);
        }
        self.redo_stack.clear();
        Ok(receipt(
            action,
            MutationStatus::Applied,
            revision_before,
            self.revision,
            timeline_id.to_owned(),
            changes,
            result.details,
        ))
    }

    fn no_op_receipt(
        &self,
        action: MutationKind,
        timeline_id: &str,
    ) -> Result<MutationReceipt, MutationError> {
        Ok(receipt(
            action,
            MutationStatus::NoOp,
            self.revision,
            self.revision,
            timeline_id.to_owned(),
            MutationChanges::default(),
            BTreeMap::new(),
        ))
    }

    fn timeline_index(&self, timeline_id: &str) -> Result<usize, MutationError> {
        self.project
            .timelines
            .iter()
            .position(|timeline| timeline.id == timeline_id)
            .ok_or_else(|| {
                MutationError::new(
                    MutationErrorCode::TimelineNotFound,
                    format!("timeline not found: {timeline_id}"),
                )
            })
    }

    fn track_index(&self, timeline_index: usize, track_id: &str) -> Result<usize, MutationError> {
        self.project.timelines[timeline_index]
            .tracks
            .iter()
            .position(|track| track.id == track_id)
            .ok_or_else(|| {
                MutationError::new(
                    MutationErrorCode::TrackNotFound,
                    format!("track not found: {track_id}"),
                )
            })
    }

    fn clip_location(
        &self,
        timeline_index: usize,
        clip_id: &str,
    ) -> Result<ClipLocation, MutationError> {
        self.project.timelines[timeline_index]
            .clip_location(clip_id)
            .ok_or_else(|| {
                MutationError::new(
                    MutationErrorCode::ClipNotFound,
                    format!("clip not found: {clip_id}"),
                )
            })
    }
}

fn receipt(
    action: MutationKind,
    status: MutationStatus,
    revision_before: u64,
    revision_after: u64,
    timeline_id: String,
    changes: MutationChanges,
    details: BTreeMap<String, Value>,
) -> MutationReceipt {
    MutationReceipt {
        action,
        status,
        revision_before,
        revision_after,
        timeline_id,
        created_clip_ids: changes.created_clip_ids,
        updated_clip_ids: changes.updated_clip_ids,
        removed_clip_ids: changes.removed_clip_ids,
        affected_track_ids: changes.affected_track_ids,
        created_track_ids: changes.created_track_ids,
        removed_track_ids: changes.removed_track_ids,
        skipped_ids: changes.skipped_ids,
        warnings: changes.warnings,
        details,
    }
}

fn validate_project(project: &ProjectFile) -> Result<(), MutationError> {
    if project.timelines.is_empty() {
        return Err(MutationError::new(
            MutationErrorCode::InvalidArgument,
            "project must contain at least one timeline",
        ));
    }
    let mut timeline_ids = HashSet::new();
    let mut track_ids = HashSet::new();
    let mut clip_ids = HashSet::new();
    for timeline in &project.timelines {
        if timeline.id.is_empty() || !timeline_ids.insert(timeline.id.clone()) {
            return Err(MutationError::new(
                MutationErrorCode::DuplicateId,
                format!("duplicate or empty timeline id: {}", timeline.id),
            ));
        }
        if timeline.fps <= 0 || timeline.width <= 0 || timeline.height <= 0 {
            return Err(MutationError::new(
                MutationErrorCode::InvalidArgument,
                format!("timeline {} has invalid settings", timeline.id),
            ));
        }
        for track in &timeline.tracks {
            if track.id.is_empty() || !track_ids.insert(track.id.clone()) {
                return Err(MutationError::new(
                    MutationErrorCode::DuplicateId,
                    format!("duplicate or empty track id: {}", track.id),
                ));
            }
            for clip in &track.clips {
                if clip.id.is_empty() || !clip_ids.insert(clip.id.clone()) {
                    return Err(MutationError::new(
                        MutationErrorCode::DuplicateId,
                        format!("duplicate or empty clip id: {}", clip.id),
                    ));
                }
                validate_clip_for_mutation(clip)?;
                if !track.track_type.is_compatible_with(clip.media_type) {
                    return Err(MutationError::new(
                        MutationErrorCode::IncompatibleTrack,
                        format!("clip {} is incompatible with track {}", clip.id, track.id),
                    ));
                }
            }
        }
    }
    Ok(())
}

fn validate_clip_for_mutation(clip: &Clip) -> Result<(), MutationError> {
    if clip.media_ref.is_empty() && clip.media_type != ClipType::Text {
        return Err(MutationError::new(
            MutationErrorCode::InvalidArgument,
            "mediaRef must not be empty",
        ));
    }
    if clip.start_frame < 0 || clip.duration_frames <= 0 {
        return Err(invalid_frame(
            "clip startFrame must be nonnegative and durationFrames must be positive",
        ));
    }
    clip.checked_end_frame().map_err(frame_error)?;
    if !clip.speed.is_finite() || clip.speed <= 0.0 {
        return Err(MutationError::new(
            MutationErrorCode::InvalidArgument,
            "clip speed must be finite and greater than zero",
        ));
    }
    for value in [
        clip.volume,
        clip.opacity,
        clip.edge_rounding,
        clip.edge_softness,
    ] {
        if !value.is_finite() {
            return Err(MutationError::new(
                MutationErrorCode::InvalidArgument,
                "clip numeric values must be finite",
            ));
        }
    }
    Ok(())
}

fn validate_track_collisions(track: &Track) -> Result<(), MutationError> {
    for clips in track.clips.windows(2) {
        if clips[0].checked_end_frame().map_err(frame_error)? > clips[1].start_frame {
            return Err(MutationError::new(
                MutationErrorCode::Collision,
                format!(
                    "clips {} and {} overlap on track {}",
                    clips[0].id, clips[1].id, track.id
                ),
            ));
        }
    }
    Ok(())
}

fn all_clip_ids(project: &ProjectFile) -> HashSet<String> {
    project
        .timelines
        .iter()
        .flat_map(|timeline| &timeline.tracks)
        .flat_map(|track| &track.clips)
        .map(|clip| clip.id.clone())
        .collect()
}

fn validate_range(range: FrameRange) -> Result<(), MutationError> {
    if range.start < 0 || range.end <= range.start {
        return Err(invalid_frame(
            "range must be nonnegative and end must be greater than start",
        ));
    }
    Ok(())
}

fn validate_trim(clip: &Clip, edit: &TrimClipRequest) -> Result<(), MutationError> {
    if clip.media_type != ClipType::Image
        && clip.media_type != ClipType::Text
        && (edit.trim_start_frame < 0 || edit.trim_end_frame < 0)
    {
        return Err(invalid_frame(
            "trim values must not be negative for bounded media",
        ));
    }
    let (start, duration) = trim_geometry(clip, edit)?;
    if start < 0 || duration <= 0 {
        return Err(invalid_frame(
            "trim would move the clip before frame zero or remove its full duration",
        ));
    }
    checked_add(start, duration).map_err(frame_error)?;
    Ok(())
}

fn trim_geometry(clip: &Clip, edit: &TrimClipRequest) -> Result<(Frame, Frame), MutationError> {
    let delta_start_source =
        checked_sub(edit.trim_start_frame, clip.trim_start_frame).map_err(frame_error)?;
    let delta_end_source =
        checked_sub(edit.trim_end_frame, clip.trim_end_frame).map_err(frame_error)?;
    let delta_start_timeline =
        swift_round(delta_start_source as f64 / clip.speed).map_err(frame_error)?;
    let delta_end_timeline =
        swift_round(delta_end_source as f64 / clip.speed).map_err(frame_error)?;
    let duration = checked_sub(
        checked_sub(clip.duration_frames, delta_start_timeline).map_err(frame_error)?,
        delta_end_timeline,
    )
    .map_err(frame_error)?;
    let start = checked_add(clip.start_frame, delta_start_timeline).map_err(frame_error)?;
    Ok((start, duration))
}

fn append_overwrite_changes(
    changes: &mut MutationChanges,
    report: crate::overwrite::OverwriteReport,
) {
    changes.created_clip_ids.extend(report.created_clip_ids);
    changes.updated_clip_ids.extend(report.updated_clip_ids);
    changes.removed_clip_ids.extend(report.removed_clip_ids);
}

fn split_straddler(
    track: &mut Track,
    frame: Frame,
    changes: &mut MutationChanges,
) -> Result<(), MutationError> {
    let Some(index) = track
        .clips
        .iter()
        .position(|clip| clip.start_frame < frame && frame < clip.end_frame())
    else {
        return Ok(());
    };
    let original = track.clips[index].clone();
    let (left, right) = split_clip_value(&original, frame, new_id()).map_err(split_error)?;
    changes.updated_clip_ids.push(left.id.clone());
    changes.created_clip_ids.push(right.id.clone());
    track.clips[index] = left;
    track.clips.push(right);
    track.sort_clips();
    Ok(())
}

fn apply_shifts(track: &mut Track, shifts: &[ClipShift], changes: &mut MutationChanges) {
    let shifts: HashMap<_, _> = shifts
        .iter()
        .map(|shift| (shift.clip_id.as_str(), shift.new_start_frame))
        .collect();
    for clip in &mut track.clips {
        if let Some(start) = shifts.get(clip.id.as_str()) {
            clip.start_frame = *start;
            changes.updated_clip_ids.push(clip.id.clone());
        }
    }
}

fn ripple_clear_track_ids(
    timeline: &Timeline,
    anchor_track_id: &str,
    ranges: &[FrameRange],
    ignored: &HashSet<String>,
) -> HashSet<String> {
    let mut clear: HashSet<_> = timeline
        .tracks
        .iter()
        .filter(|track| {
            track.id == anchor_track_id || (track.sync_locked && !ignored.contains(&track.id))
        })
        .map(|track| track.id.clone())
        .collect();
    let links = link_index(timeline);
    loop {
        let mut added = false;
        let current = clear.iter().cloned().collect::<Vec<_>>();
        for track_id in current {
            let Some(track) = timeline.tracks.iter().find(|track| track.id == track_id) else {
                continue;
            };
            for clip in &track.clips {
                if !ranges
                    .iter()
                    .any(|range| range.start < clip.end_frame() && range.end > clip.start_frame)
                {
                    continue;
                }
                let Some(group) = &clip.link_group_id else {
                    continue;
                };
                for partner_id in links.get(group).into_iter().flatten() {
                    if let Some(partner_location) = timeline.clip_location(partner_id) {
                        let partner_track = &timeline.tracks[partner_location.track_index];
                        added |= clear.insert(partner_track.id.clone());
                    }
                }
            }
        }
        if !added {
            break;
        }
    }
    clear
}

fn validate_multicam_atomicity(
    timeline: &Timeline,
    shifting_track_ids: &HashSet<String>,
) -> Result<(), MutationError> {
    let mut groups = HashMap::<String, HashSet<String>>::new();
    for track in &timeline.tracks {
        for clip in &track.clips {
            if let Some(group) = &clip.multicam_group_id {
                groups
                    .entry(group.clone())
                    .or_default()
                    .insert(track.id.clone());
            }
        }
    }
    for (group, track_ids) in groups {
        let moving = track_ids.intersection(shifting_track_ids).count();
        if moving > 0 && moving != track_ids.len() {
            return Err(MutationError::new(
                MutationErrorCode::MulticamAtomicity,
                format!("ripple would shift only part of multicam group {group}"),
            ));
        }
    }
    Ok(())
}

fn link_index(timeline: &Timeline) -> HashMap<String, Vec<String>> {
    let mut result = HashMap::<String, Vec<String>>::new();
    for clip in timeline.tracks.iter().flat_map(|track| &track.clips) {
        if let Some(group) = &clip.link_group_id {
            result
                .entry(group.clone())
                .or_default()
                .push(clip.id.clone());
        }
    }
    result
}

fn expand_link_groups(timeline: &Timeline, ids: &HashSet<String>) -> HashSet<String> {
    let index = link_index(timeline);
    let mut groups = HashSet::new();
    for (group, members) in &index {
        if members.iter().any(|member| ids.contains(member)) {
            groups.insert(group);
        }
    }
    let mut result = ids.clone();
    for group in groups {
        if let Some(members) = index.get(group) {
            result.extend(members.iter().cloned());
        }
    }
    result
}

fn linked_partner_ids(timeline: &Timeline, clip_id: &str) -> Vec<String> {
    let Some(location) = timeline.clip_location(clip_id) else {
        return Vec::new();
    };
    let clip = &timeline.tracks[location.track_index].clips[location.clip_index];
    let Some(group) = &clip.link_group_id else {
        return Vec::new();
    };
    link_index(timeline)
        .get(group)
        .cloned()
        .unwrap_or_default()
}

fn is_slip_eligible(clip: &Clip) -> bool {
    !matches!(clip.media_type, ClipType::Image | ClipType::Text)
        && clip.multicam_group_id.is_none()
}

fn effective_trim_end(project: &ProjectFile, clip: &Clip) -> Frame {
    if clip.source_clip_type == ClipType::Sequence {
        if let Some(child) = project
            .timelines
            .iter()
            .find(|timeline| timeline.id == clip.media_ref)
        {
            return (child.total_frames() - clip.trim_start_frame - clip.duration_frames).max(0);
        }
    }
    clip.trim_end_frame.max(0)
}

fn retimed_duration_frames(
    duration_frames: Frame,
    speed: f64,
    new_speed: f64,
) -> Result<Frame, MutationError> {
    if !new_speed.is_finite() || new_speed <= 0.0 || !speed.is_finite() || speed <= 0.0 {
        return Err(MutationError::new(
            MutationErrorCode::InvalidArgument,
            "clip speed must be finite and greater than zero",
        ));
    }
    let scaled = swift_round(duration_frames as f64 * speed / new_speed).map_err(frame_error)?;
    Ok(scaled.max(1))
}

fn validate_keyframe_frame(clip: &Clip, frame: Frame) -> Result<(), MutationError> {
    if frame < clip.start_frame || frame > clip.end_frame() {
        return Err(invalid_frame(
            "keyframe frame must be within the clip, including its end boundary",
        ));
    }
    Ok(())
}

fn validate_keyframe_value(
    property: AnimatableProperty,
    value: &KeyframeValue,
) -> Result<(), MutationError> {
    let valid = matches!(
        (property, value),
        (
            AnimatableProperty::Opacity | AnimatableProperty::Rotation | AnimatableProperty::Volume,
            KeyframeValue::Number(_)
        ) | (
            AnimatableProperty::Position | AnimatableProperty::Scale,
            KeyframeValue::Pair(_)
        ) | (AnimatableProperty::Crop, KeyframeValue::Crop(_))
    );
    if !valid {
        return Err(MutationError::new(
            MutationErrorCode::InvalidArgument,
            "keyframe value does not match the property",
        ));
    }
    let finite = match value {
        KeyframeValue::Number(value) => value.is_finite(),
        KeyframeValue::Pair(value) => value.a.is_finite() && value.b.is_finite(),
        KeyframeValue::Crop(value) => [value.left, value.top, value.right, value.bottom]
            .into_iter()
            .all(f64::is_finite),
    };
    if !finite {
        return Err(MutationError::new(
            MutationErrorCode::InvalidArgument,
            "keyframe values must be finite",
        ));
    }
    Ok(())
}

fn upsert_track<T: Clone + PartialEq>(
    track: &mut Option<KeyframeTrack<T>>,
    frame: Frame,
    value: T,
) {
    let target = track.get_or_insert_with(KeyframeTrack::default);
    target.upsert(Keyframe::new(frame, value));
}

fn remove_from_track<T: Clone + PartialEq>(track: &mut Option<KeyframeTrack<T>>, frame: Frame) {
    if let Some(target) = track {
        target.remove(frame);
        if target.keyframes.is_empty() {
            *track = None;
        }
    }
}

fn move_in_track<T: Clone + PartialEq>(
    track: &mut Option<KeyframeTrack<T>>,
    from: Frame,
    to: Frame,
) {
    if let Some(target) = track {
        target.move_keyframe(from, to);
    }
}

fn set_track_interpolation<T>(
    track: &mut Option<KeyframeTrack<T>>,
    frame: Frame,
    interpolation: Interpolation,
) {
    if let Some(keyframe) = track.as_mut().and_then(|track| {
        track
            .keyframes
            .iter_mut()
            .find(|keyframe| keyframe.frame == frame)
    }) {
        keyframe.interpolation_out = interpolation;
    }
}

fn ensure_unique_ids(ids: &[String], entity: &str) -> Result<(), MutationError> {
    let mut seen = HashSet::new();
    for id in ids {
        if !seen.insert(id) {
            return Err(MutationError::new(
                MutationErrorCode::DuplicateId,
                format!("{entity} id appears more than once: {id}"),
            ));
        }
    }
    Ok(())
}

fn would_create_nest_cycle(project: &ProjectFile, child_id: &str, parent_id: &str) -> bool {
    if child_id == parent_id {
        return true;
    }
    let Some(child) = project
        .timelines
        .iter()
        .find(|timeline| timeline.id == child_id)
    else {
        return false;
    };
    child
        .reachable_timeline_ids(&project.timelines, usize::MAX)
        .iter()
        .any(|id| id == parent_id)
}

fn source_dimensions(
    project: &ProjectFile,
    manifest: &MediaManifest,
) -> HashMap<String, (i32, i32)> {
    let mut dimensions = manifest
        .entries
        .iter()
        .filter_map(|entry| {
            Some((
                entry.id.clone(),
                (entry.source_width?, entry.source_height?),
            ))
        })
        .filter(|(_, (width, height))| *width > 0 && *height > 0)
        .collect::<HashMap<_, _>>();
    for timeline in &project.timelines {
        dimensions.insert(timeline.id.clone(), (timeline.width, timeline.height));
    }
    dimensions
}

fn rescale_timeline(timeline: &mut Timeline, scale: f64) -> Result<(), MutationError> {
    for track in &mut timeline.tracks {
        track.sort_clips();
        let mut previous_end = None;
        for clip in &mut track.clips {
            let scaled_start = swift_round(clip.start_frame as f64 * scale).map_err(frame_error)?;
            let scaled_end = swift_round(clip.end_frame() as f64 * scale).map_err(frame_error)?;
            clip.start_frame = scaled_start.max(previous_end.unwrap_or(scaled_start));
            clip.duration_frames = checked_sub(scaled_end, clip.start_frame)
                .map_err(frame_error)?
                .max(1);
            clip.trim_start_frame =
                swift_round(clip.trim_start_frame as f64 * scale).map_err(frame_error)?;
            clip.trim_end_frame =
                swift_round(clip.trim_end_frame as f64 * scale).map_err(frame_error)?;
            clip.rescale_keyframes(scale).map_err(frame_error)?;
            clip.fade_in_frames =
                swift_round(clip.fade_in_frames as f64 * scale).map_err(frame_error)?;
            clip.fade_out_frames =
                swift_round(clip.fade_out_frames as f64 * scale).map_err(frame_error)?;
            clip.clamp_keyframes_to_duration();
            clip.clamp_fades_to_duration();
            previous_end = Some(clip.end_frame());
        }
    }
    Ok(())
}

fn fit_transform(
    source_width: i32,
    source_height: i32,
    canvas_width: i32,
    canvas_height: i32,
) -> Transform {
    if source_width <= 0 || source_height <= 0 || canvas_width <= 0 || canvas_height <= 0 {
        return Transform::default();
    }
    let canvas_aspect = f64::from(canvas_width) / f64::from(canvas_height);
    let relative_aspect = (f64::from(source_width) / f64::from(source_height)) / canvas_aspect;
    let source_aspect = relative_aspect * canvas_aspect;
    if (canvas_aspect - source_aspect).abs() < 0.02 {
        Transform::default()
    } else if relative_aspect > 1.0 {
        Transform {
            width: 1.0,
            height: 1.0 / relative_aspect,
            ..Transform::default()
        }
    } else {
        Transform {
            width: relative_aspect,
            height: 1.0,
            ..Transform::default()
        }
    }
}

fn transform_scale_matches(left: Transform, right: Transform) -> bool {
    (left.width - right.width).abs() < 0.0001 && (left.height - right.height).abs() < 0.0001
}

fn invalid_frame(message: impl Into<String>) -> MutationError {
    MutationError::new(MutationErrorCode::InvalidFrame, message)
}

fn frame_error(error: crate::frames::FrameError) -> MutationError {
    MutationError::new(
        MutationErrorCode::ArithmeticOverflow,
        format!("frame calculation failed: {error}"),
    )
}

fn split_error(error: SplitError) -> MutationError {
    match error {
        SplitError::OutsideClip => {
            invalid_frame("the split frame must be strictly inside the clip")
        }
        SplitError::Frame(error) => frame_error(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{AnimPair, Crop, KeyframeTrack};

    fn clip(id: &str, media_type: ClipType, start: Frame, duration: Frame) -> Clip {
        let mut clip = Clip::new("media", start, duration);
        clip.id = id.to_owned();
        clip.media_type = media_type;
        clip.source_clip_type = media_type;
        clip
    }

    fn session(tracks: Vec<Track>) -> EditorSession {
        let timeline = Timeline {
            id: "timeline".to_owned(),
            tracks,
            ..Timeline::default()
        };
        EditorSession::new(ProjectFile::new(vec![timeline]).unwrap()).unwrap()
    }

    fn track(id: &str, track_type: ClipType, clips: Vec<Clip>) -> Track {
        Track {
            id: id.to_owned(),
            clips,
            ..Track::new(track_type)
        }
    }

    fn spans(session: &EditorSession, track_id: &str) -> Vec<(Frame, Frame)> {
        let timeline = &session.project.timelines[0];
        let track = timeline
            .tracks
            .iter()
            .find(|track| track.id == track_id)
            .unwrap();
        track
            .clips
            .iter()
            .map(|clip| (clip.start_frame, clip.end_frame()))
            .collect()
    }

    #[test]
    fn add_overwrites_existing_content_and_returns_ids() {
        let mut session = session(vec![track(
            "v1",
            ClipType::Video,
            vec![clip("old", ClipType::Video, 0, 100)],
        )]);
        let receipt = session
            .add_clips(
                "timeline",
                "v1",
                40,
                vec![clip("new", ClipType::Video, 0, 20)],
                AddMode::Overwrite,
            )
            .unwrap();
        assert_eq!(receipt.status, MutationStatus::Applied);
        assert!(receipt.created_clip_ids.contains(&"new".to_owned()));
        assert_eq!(receipt.created_clip_ids.len(), 2);
        assert_eq!(spans(&session, "v1"), vec![(0, 40), (40, 60), (60, 100)]);
    }

    #[test]
    fn ripple_add_opens_a_gap_without_overwriting() {
        let mut session = session(vec![track(
            "v1",
            ClipType::Video,
            vec![
                clip("first", ClipType::Video, 0, 50),
                clip("second", ClipType::Video, 50, 50),
            ],
        )]);
        session
            .add_clips(
                "timeline",
                "v1",
                50,
                vec![clip("inserted", ClipType::Video, 0, 30)],
                AddMode::Ripple,
            )
            .unwrap();
        assert_eq!(spans(&session, "v1"), vec![(0, 50), (50, 80), (80, 130)]);
    }

    #[test]
    fn move_is_atomic_and_clears_the_destination() {
        let mut session = session(vec![
            track(
                "v1",
                ClipType::Video,
                vec![clip("moving", ClipType::Video, 0, 30)],
            ),
            track(
                "v2",
                ClipType::Video,
                vec![clip("blocked", ClipType::Video, 90, 30)],
            ),
        ]);
        session
            .move_clips(
                "timeline",
                vec![MoveClipRequest {
                    clip_id: "moving".to_owned(),
                    track_id: "v2".to_owned(),
                    start_frame: 100,
                }],
            )
            .unwrap();
        assert_eq!(spans(&session, "v2"), vec![(90, 100), (100, 130)]);
    }

    #[test]
    fn split_cuts_linked_partners_and_regroups_right_halves() {
        let mut video = clip("video", ClipType::Video, 0, 60);
        let mut audio = clip("audio", ClipType::Audio, 0, 60);
        video.link_group_id = Some("group".to_owned());
        audio.link_group_id = Some("group".to_owned());
        let mut session = session(vec![
            track("v1", ClipType::Video, vec![video]),
            track("a1", ClipType::Audio, vec![audio]),
        ]);
        let receipt = session.split_clip("timeline", "video", 30).unwrap();
        assert_eq!(receipt.created_clip_ids.len(), 2);
        let right_groups = session.project.timelines[0]
            .tracks
            .iter()
            .flat_map(|track| &track.clips)
            .filter(|clip| receipt.created_clip_ids.contains(&clip.id))
            .filter_map(|clip| clip.link_group_id.clone())
            .collect::<HashSet<_>>();
        assert_eq!(right_groups.len(), 1);
        assert!(!right_groups.contains("group"));
    }

    #[test]
    fn trim_converts_source_delta_through_speed() {
        let mut value = clip("clip", ClipType::Video, 0, 100);
        value.speed = 2.0;
        let mut session = session(vec![track("v1", ClipType::Video, vec![value])]);
        session
            .trim_clips(
                "timeline",
                vec![TrimClipRequest {
                    clip_id: "clip".to_owned(),
                    trim_start_frame: 20,
                    trim_end_frame: 0,
                }],
            )
            .unwrap();
        assert_eq!(spans(&session, "v1"), vec![(10, 100)]);
    }

    #[test]
    fn ripple_delete_cuts_mid_clip_and_closes_the_gap() {
        let mut session = session(vec![track(
            "v1",
            ClipType::Video,
            vec![clip("clip", ClipType::Video, 0, 100)],
        )]);
        let receipt = session
            .ripple_delete_ranges(
                "timeline",
                "v1",
                &[FrameRange { start: 40, end: 50 }],
                &HashSet::new(),
            )
            .unwrap();
        assert_eq!(spans(&session, "v1"), vec![(0, 40), (40, 90)]);
        assert_eq!(receipt.details["removedFrames"], json!(10));
    }

    #[test]
    fn ripple_delete_cuts_linked_and_sync_locked_tracks() {
        let mut video = clip("video", ClipType::Video, 0, 100);
        let mut audio = clip("audio", ClipType::Audio, 0, 100);
        video.link_group_id = Some("group".to_owned());
        audio.link_group_id = Some("group".to_owned());
        let mut session = session(vec![
            track("v1", ClipType::Video, vec![video]),
            track("a1", ClipType::Audio, vec![audio]),
        ]);
        session
            .ripple_delete_ranges(
                "timeline",
                "v1",
                &[FrameRange { start: 40, end: 50 }],
                &HashSet::new(),
            )
            .unwrap();
        assert_eq!(spans(&session, "v1"), spans(&session, "a1"));
    }

    #[test]
    fn link_and_unlink_expand_existing_groups() {
        let video = clip("video", ClipType::Video, 0, 30);
        let audio = clip("audio", ClipType::Audio, 0, 30);
        let mut session = session(vec![
            track("v1", ClipType::Video, vec![video]),
            track("a1", ClipType::Audio, vec![audio]),
        ]);
        session
            .link_clips("timeline", &["video".to_owned(), "audio".to_owned()])
            .unwrap();
        session
            .unlink_clips("timeline", &["video".to_owned()])
            .unwrap();
        assert!(
            session.project.timelines[0]
                .tracks
                .iter()
                .flat_map(|track| &track.clips)
                .all(|clip| clip.link_group_id.is_none())
        );
    }

    #[test]
    fn track_insertion_preserves_visual_audio_partition() {
        let mut session = session(vec![track("a1", ClipType::Audio, Vec::new())]);
        let receipt = session
            .add_track("timeline", ClipType::Video, usize::MAX)
            .unwrap();
        assert_eq!(receipt.details["trackIndex"], json!(0));
        assert_eq!(
            session.project.timelines[0].tracks[0].track_type,
            ClipType::Video
        );
    }

    #[test]
    fn track_updates_reorder_and_remove_are_snapshot_undoable() {
        let mut session = session(vec![
            track("v1", ClipType::Video, Vec::new()),
            track("v2", ClipType::Video, Vec::new()),
            track("a1", ClipType::Audio, Vec::new()),
        ]);
        session
            .update_track(
                "timeline",
                "v1",
                TrackPatch {
                    hidden: Some(true),
                    display_height: Some(1_000.0),
                    ..TrackPatch::default()
                },
            )
            .unwrap();
        session.reorder_track("timeline", "v1", 1).unwrap();
        session
            .remove_tracks("timeline", &["a1".to_owned()])
            .unwrap();
        assert_eq!(
            session.project.timelines[0]
                .tracks
                .iter()
                .map(|track| track.id.as_str())
                .collect::<Vec<_>>(),
            vec!["v2", "v1"]
        );
        assert!(session.project.timelines[0].tracks[1].hidden);
        assert_eq!(session.project.timelines[0].tracks[1].display_height, 200.0);
        session.undo().unwrap();
        assert!(
            session.project.timelines[0]
                .tracks
                .iter()
                .any(|track| track.id == "a1")
        );
    }

    #[test]
    fn keyframes_use_absolute_api_frames_and_relative_storage() {
        let value = clip("clip", ClipType::Video, 100, 60);
        let mut session = session(vec![track("v1", ClipType::Video, vec![value])]);
        session
            .upsert_keyframe(
                "timeline",
                "clip",
                AnimatableProperty::Position,
                110,
                KeyframeValue::Pair(AnimPair { a: 0.1, b: 0.2 }),
            )
            .unwrap();
        let stored = session.project.timelines[0].tracks[0].clips[0]
            .position_track
            .as_ref()
            .unwrap();
        assert_eq!(stored.keyframes[0].frame, 10);
    }

    #[test]
    fn keyframe_type_mismatch_is_a_validation_failure_without_history() {
        let value = clip("clip", ClipType::Video, 0, 60);
        let mut session = session(vec![track("v1", ClipType::Video, vec![value])]);
        let before = session.snapshot();
        assert!(
            session
                .upsert_keyframe(
                    "timeline",
                    "clip",
                    AnimatableProperty::Crop,
                    10,
                    KeyframeValue::Number(1.0),
                )
                .is_err()
        );
        assert_eq!(session.snapshot(), before);
        assert_eq!(session.undo_depth(), 0);
        assert_eq!(session.revision(), 0);
    }

    #[test]
    fn a_failure_after_partial_work_rolls_back_without_history() {
        let mut value = clip("clip", ClipType::Video, 0, 60);
        value.multicam_group_id = Some("multicam".to_owned());
        let mut session = session(vec![track("v1", ClipType::Video, vec![value])]);
        let result = session.update_track(
            "timeline",
            "v1",
            TrackPatch {
                hidden: Some(true),
                sync_locked: Some(false),
                ..TrackPatch::default()
            },
        );
        assert!(result.is_err());
        assert!(!session.project.timelines[0].tracks[0].hidden);
        assert!(session.project.timelines[0].tracks[0].sync_locked);
        assert_eq!(session.undo_depth(), 0);
        assert_eq!(session.revision(), 0);
    }

    #[test]
    fn copy_paste_freshens_ids_and_preserves_complete_link_groups() {
        let mut video = clip("video", ClipType::Video, 0, 30);
        let mut audio = clip("audio", ClipType::Audio, 0, 30);
        video.link_group_id = Some("group".to_owned());
        audio.link_group_id = Some("group".to_owned());
        let mut session = session(vec![
            track("v1", ClipType::Video, vec![video]),
            track("a1", ClipType::Audio, vec![audio]),
        ]);
        session
            .copy_clips("timeline", &["video".to_owned(), "audio".to_owned()])
            .unwrap();
        let receipt = session.paste_clips("timeline", "v1", 100).unwrap();
        assert_eq!(receipt.created_clip_ids.len(), 2);
        let groups = session.project.timelines[0]
            .tracks
            .iter()
            .flat_map(|track| &track.clips)
            .filter(|clip| receipt.created_clip_ids.contains(&clip.id))
            .filter_map(|clip| clip.link_group_id.clone())
            .collect::<HashSet<_>>();
        assert_eq!(groups.len(), 1);
        assert!(!groups.contains("group"));
    }

    #[test]
    fn project_settings_rescale_frames_keyframes_and_view_state() {
        let mut value = clip("clip", ClipType::Video, 30, 60);
        value.opacity_track = Some(KeyframeTrack {
            keyframes: vec![Keyframe::new(15, 0.5)],
        });
        let mut session = session(vec![track("v1", ClipType::Video, vec![value])]);
        session.project.view_states = Some(BTreeMap::from([(
            "timeline".to_owned(),
            crate::models::TimelineViewState {
                playhead_frame: 90,
                ..crate::models::TimelineViewState::default()
            },
        )]));
        session
            .apply_project_settings("timeline", 60, 1920, 1080)
            .unwrap();
        let clip = &session.project.timelines[0].tracks[0].clips[0];
        assert_eq!((clip.start_frame, clip.duration_frames), (60, 120));
        assert_eq!(clip.opacity_track.as_ref().unwrap().keyframes[0].frame, 30);
        assert_eq!(
            session.project.view_states.as_ref().unwrap()["timeline"].playhead_frame,
            180
        );
    }

    #[test]
    fn no_ops_and_validation_failures_never_create_undo_entries() {
        let value = clip("clip", ClipType::Video, 0, 30);
        let mut session = session(vec![track("v1", ClipType::Video, vec![value])]);
        let no_op = session.split_clip("timeline", "clip", 0).unwrap();
        assert_eq!(no_op.status, MutationStatus::NoOp);
        assert_eq!(session.undo_depth(), 0);
        assert!(
            session
                .move_clips(
                    "timeline",
                    vec![MoveClipRequest {
                        clip_id: "missing".to_owned(),
                        track_id: "v1".to_owned(),
                        start_frame: 0,
                    }],
                )
                .is_err()
        );
        assert_eq!(session.undo_depth(), 0);
        assert_eq!(session.revision(), 0);
    }

    #[test]
    fn moving_to_the_current_location_is_a_no_op() {
        let value = clip("clip", ClipType::Video, 10, 30);
        let mut session = session(vec![track("v1", ClipType::Video, vec![value])]);
        let receipt = session
            .move_clips(
                "timeline",
                vec![MoveClipRequest {
                    clip_id: "clip".to_owned(),
                    track_id: "v1".to_owned(),
                    start_frame: 10,
                }],
            )
            .unwrap();
        assert_eq!(receipt.status, MutationStatus::NoOp);
        assert_eq!(session.undo_depth(), 0);
    }

    #[test]
    fn undo_redo_restore_exact_snapshots_and_keep_revision_monotonic() {
        let value = clip("clip", ClipType::Video, 0, 60);
        let mut session = session(vec![track("v1", ClipType::Video, vec![value])]);
        let original = session.snapshot();
        session.split_clip("timeline", "clip", 30).unwrap();
        let edited = session.snapshot();
        assert_eq!(session.revision(), 1);

        let undo = session.undo().unwrap();
        assert_eq!(undo.status, MutationStatus::Undone);
        assert_eq!(session.snapshot(), original);
        assert_eq!(session.revision(), 2);

        let redo = session.redo().unwrap();
        assert_eq!(redo.status, MutationStatus::Redone);
        assert_eq!(session.snapshot(), edited);
        assert_eq!(session.revision(), 3);
    }

    #[test]
    fn preview_executes_against_a_clone_without_mutating_the_session() {
        let session = session(vec![]);
        let before = session.snapshot();
        let (receipt, preview) = session
            .preview(EditorCommand::AddTrack {
                timeline_id: "timeline".to_owned(),
                track_type: ClipType::Video,
                requested_index: 0,
            })
            .unwrap();
        assert_eq!(receipt.status, MutationStatus::Applied);
        assert_eq!(receipt.revision_after, 1);
        assert_eq!(preview.project.timelines[0].tracks.len(), 1);
        assert_eq!(session.snapshot(), before);
        assert_eq!(session.revision(), 0);
        assert_eq!(session.undo_depth(), 0);
    }

    #[test]
    fn crop_keyframe_values_round_trip_through_commands() {
        let command = EditorCommand::UpsertKeyframe {
            timeline_id: "timeline".to_owned(),
            clip_id: "clip".to_owned(),
            property: AnimatableProperty::Crop,
            frame: 10,
            value: KeyframeValue::Crop(Crop {
                left: 0.1,
                ..Crop::default()
            }),
        };
        let value = serde_json::to_value(&command).unwrap();
        assert_eq!(
            serde_json::from_value::<EditorCommand>(value).unwrap(),
            command
        );
    }

    #[test]
    fn clip_updates_are_atomic_and_undoable() {
        let value = clip("clip", ClipType::Video, 0, 60);
        let mut session = session(vec![track("v1", ClipType::Video, vec![value])]);
        let mut replacement = session.project().timelines[0].tracks[0].clips[0].clone();
        replacement.opacity = 0.5;
        replacement.speed = 2.0;

        let receipt = session
            .execute(EditorCommand::UpdateClips {
                timeline_id: "timeline".into(),
                clips: vec![replacement],
            })
            .unwrap();

        assert_eq!(receipt.status, MutationStatus::Applied);
        assert_eq!(session.project().timelines[0].tracks[0].clips[0].opacity, 0.5);
        session.undo().unwrap();
        assert_eq!(session.project().timelines[0].tracks[0].clips[0].opacity, 1.0);
    }

    #[test]
    fn timeline_creation_and_activation_are_undoable() {
        let mut session = session(vec![]);
        let created = Timeline {
            id: "second".into(),
            name: "Second".into(),
            ..Timeline::default()
        };
        session
            .execute(EditorCommand::CreateTimeline {
                timeline: created,
                make_active: true,
            })
            .unwrap();
        assert_eq!(session.project().active_timeline_id(), Some("second"));
        session.undo().unwrap();
        assert_eq!(session.project().timelines.len(), 1);
    }

    #[test]
    fn slip_shifts_source_window_without_moving_clip() {
        let mut value = clip("clip", ClipType::Video, 10, 30);
        value.trim_start_frame = 20;
        value.trim_end_frame = 40;
        let mut session = session(vec![track("v1", ClipType::Video, vec![value])]);
        let receipt = session
            .execute(EditorCommand::SlipClips {
                timeline_id: "timeline".into(),
                clip_id: "clip".into(),
                delta_frames: 5,
                propagate_to_linked: true,
            })
            .unwrap();
        assert_eq!(receipt.status, MutationStatus::Applied);
        let clip = &session.project().timelines[0].tracks[0].clips[0];
        assert_eq!(clip.start_frame, 10);
        assert_eq!(clip.duration_frames, 30);
        assert_eq!(clip.trim_start_frame, 15);
        assert_eq!(clip.trim_end_frame, 45);
    }

    #[test]
    fn set_clip_speed_retimes_duration_and_ripples() {
        let lead = clip("lead", ClipType::Video, 0, 60);
        let trail = clip("trail", ClipType::Video, 60, 30);
        let mut session = session(vec![track("v1", ClipType::Video, vec![lead, trail])]);
        session
            .execute(EditorCommand::SetClipSpeed {
                timeline_id: "timeline".into(),
                clip_ids: vec!["lead".into()],
                speed: 2.0,
                ripple: true,
            })
            .unwrap();
        let track = &session.project().timelines[0].tracks[0];
        assert_eq!(track.clips[0].speed, 2.0);
        assert_eq!(track.clips[0].duration_frames, 30);
        assert_eq!(track.clips[1].start_frame, 30);
    }
}
