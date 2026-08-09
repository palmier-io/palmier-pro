use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;

use palmier_core::{
    AddMode, Clip, ClipType, EditorCommand, Effect, EffectParam, FrameRange, MediaFolder,
    MoveClipRequest, MutationReceipt, TextStyle, Timeline, TrackPatch, new_id,
};
use palmier_generation::{
    GenerateAudioParams, GenerateImageParams, GenerateVideoParams, GenerationService,
    UpscaleMediaParams, generate_audio, generate_image, generate_video, list_models,
    upscale_media,
};
use palmier_service::{EditorService, ImportMode, ProjectView};
use serde_json::{Map, Value, json};
use uuid::Uuid;

use crate::backend::{
    BoxFut, CreateProjectRequest, McpEditorBackend, ProjectSelector,
};
use crate::error::{BackendError, BackendResult};

pub struct EditorServiceBackend {
    editor: EditorService,
    generation: Option<Arc<GenerationService>>,
}

impl EditorServiceBackend {
    pub fn new(editor: EditorService) -> Self {
        Self {
            editor,
            generation: None,
        }
    }

    pub fn with_generation(
        editor: EditorService,
        generation: Arc<GenerationService>,
    ) -> Self {
        Self {
            editor,
            generation: Some(generation),
        }
    }

    async fn active_view(&self) -> BackendResult<ProjectView> {
        let summary = self
            .editor
            .list_open_projects()
            .await
            .into_iter()
            .next()
            .ok_or(BackendError::InactiveProject)?;
        self.editor
            .project_view(summary.project_id)
            .await
            .map_err(service_error)
    }

    async fn commit_value(
        &self,
        view: &ProjectView,
        command: EditorCommand,
    ) -> BackendResult<Value> {
        let result = self
            .editor
            .commit_edit(view.summary.project_id, view.summary.revision, command)
            .await
            .map_err(service_error)?;
        serde_json::to_value(result).map_err(json_error)
    }

    fn active_timeline(view: &ProjectView) -> BackendResult<&Timeline> {
        view.summary
            .active_timeline_id
            .as_deref()
            .and_then(|id| {
                view.snapshot
                    .project
                    .timelines
                    .iter()
                    .find(|timeline| timeline.id == id)
            })
            .or_else(|| view.snapshot.project.timelines.first())
            .ok_or_else(|| BackendError::message("project has no active timeline"))
    }

    fn generation(&self) -> BackendResult<&GenerationService> {
        self.generation
            .as_deref()
            .ok_or_else(|| BackendError::message("generation is unavailable"))
    }
}

impl McpEditorBackend for EditorServiceBackend {
    fn list_projects(&self) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            Ok(json!({
                "open": self.editor.list_open_projects().await,
                "recent": self.editor.list_recent_projects().await,
            }))
        })
    }

    fn open_project(&self, request: ProjectSelector) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let path = request
                .path
                .ok_or_else(|| BackendError::message("path is required"))?;
            let view = self.editor.open_project(path).await.map_err(service_error)?;
            serde_json::to_value(view).map_err(json_error)
        })
    }

    fn create_project(&self, _request: CreateProjectRequest) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let view = self.editor.create_project().await.map_err(service_error)?;
            serde_json::to_value(view).map_err(json_error)
        })
    }

    fn close_project(&self, request: ProjectSelector) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let project_id = match request.id {
                Some(id) => Uuid::parse_str(&id)
                    .map_err(|_| BackendError::message("project id is invalid"))?,
                None => self.active_view().await?.summary.project_id,
            };
            self.editor
                .close_project(project_id)
                .await
                .map_err(service_error)?;
            Ok(json!({"closed": true, "id": project_id}))
        })
    }

    fn has_active_project(&self) -> BoxFut<'_, bool> {
        Box::pin(async move { !self.editor.list_open_projects().await.is_empty() })
    }

    fn id_universe(&self) -> BoxFut<'_, BackendResult<HashSet<String>>> {
        Box::pin(async move {
            let view = self.active_view().await?;
            let mut ids = HashSet::from([view.summary.project_id.to_string()]);
            for timeline in &view.snapshot.project.timelines {
                ids.insert(timeline.id.clone());
                for track in &timeline.tracks {
                    ids.insert(track.id.clone());
                    ids.extend(track.clips.iter().map(|clip| clip.id.clone()));
                }
            }
            ids.extend(
                view.snapshot
                    .media_manifest
                    .entries
                    .iter()
                    .map(|entry| entry.id.clone()),
            );
            ids.extend(
                view.snapshot
                    .media_manifest
                    .folders
                    .iter()
                    .map(|folder| folder.id.clone()),
            );
            Ok(ids)
        })
    }

    fn get_timeline(&self, _args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let view = self.active_view().await?;
            let timeline = Self::active_timeline(&view)?;
            Ok(json!({
                "projectId": view.summary.project_id,
                "revision": view.summary.revision,
                "timeline": timeline,
            }))
        })
    }

    fn create_timeline(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let map = object(&args)?;
            let view = self.active_view().await?;
            let active = Self::active_timeline(&view)?;
            let name = string(map, "name")?;
            let from = string(map, "from")?;
            let mut timeline = if let Some(ref from) = from {
                view.snapshot
                    .project
                    .timelines
                    .iter()
                    .find(|timeline| timeline.id == *from)
                    .cloned()
                    .ok_or_else(|| BackendError::message(format!("timeline not found: {from}")))?
            } else {
                Timeline {
                    name: name.clone().unwrap_or_else(|| {
                        format!("Timeline {}", view.snapshot.project.timelines.len() + 1)
                    }),
                    fps: active.fps,
                    width: active.width,
                    height: active.height,
                    settings_configured: active.settings_configured,
                    ..Timeline::default()
                }
            };
            if from.is_some() {
                let mut groups = std::collections::HashMap::new();
                timeline.id = new_id();
                for track in &mut timeline.tracks {
                    track.id = new_id();
                    for clip in &mut track.clips {
                        clip.freshen_ids(&mut groups);
                    }
                }
            }
            if let Some(name) = name {
                timeline.name = name;
            }
            self.commit_value(
                &view,
                EditorCommand::CreateTimeline {
                    timeline,
                    make_active: true,
                },
            )
            .await
        })
    }

    fn set_active_timeline(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let view = self.active_view().await?;
            let timeline_id = required_string(object(&args)?, "timelineId")?;
            self.commit_value(&view, EditorCommand::SetActiveTimeline { timeline_id })
                .await
        })
    }

    fn set_project_settings(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let map = object(&args)?;
            let view = self.active_view().await?;
            let timeline = Self::active_timeline(&view)?;
            let fps = integer(map, "fps")?.unwrap_or(i64::from(timeline.fps));
            let width = integer(map, "width")?.unwrap_or(i64::from(timeline.width));
            let height = integer(map, "height")?.unwrap_or(i64::from(timeline.height));
            self.commit_value(
                &view,
                EditorCommand::ChangeProjectSettings {
                    timeline_id: timeline.id.clone(),
                    fps: i32::try_from(fps)
                        .map_err(|_| BackendError::message("fps is out of range"))?,
                    width: i32::try_from(width)
                        .map_err(|_| BackendError::message("width is out of range"))?,
                    height: i32::try_from(height)
                        .map_err(|_| BackendError::message("height is out of range"))?,
                },
            )
            .await
        })
    }

    fn get_media(&self, _args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let view = self.active_view().await?;
            Ok(json!({
                "assets": view.snapshot.media_manifest.entries,
                "folders": view.snapshot.media_manifest.folders,
                "timelines": view.snapshot.project.timelines.iter().map(|timeline| {
                    json!({
                        "timelineId": timeline.id,
                        "name": timeline.name,
                        "active": Some(timeline.id.as_str()) == view.snapshot.project.active_timeline_id(),
                    })
                }).collect::<Vec<_>>(),
            }))
        })
    }

    fn import_media(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let source = object(
                object(&args)?
                    .get("source")
                    .ok_or_else(|| BackendError::message("source is required"))?,
            )?;
            let path = required_string(source, "path")?;
            let view = self.active_view().await?;
            let result = self
                .editor
                .import_local_files(
                    view.summary.project_id,
                    [PathBuf::from(path)],
                    if view.summary.path.is_some() {
                        ImportMode::InstallIntoPackage
                    } else {
                        ImportMode::ExternalRefs
                    },
                    None,
                )
                .await
                .map_err(service_error)?;
            serde_json::to_value(result).map_err(json_error)
        })
    }

    fn organize_media(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let map = object(&args)?;
            let view = self.active_view().await?;
            let timeline_id = Self::active_timeline(&view)?.id.clone();
            let mut manifest = view.snapshot.media_manifest.clone();
            let mut created = Vec::new();
            if let Some(folders) = array(map, "createFolders")? {
                for name in folders {
                    let name = name
                        .as_str()
                        .ok_or_else(|| BackendError::message("folder names must be strings"))?;
                    let folder = MediaFolder {
                        id: new_id(),
                        name: name.to_owned(),
                        parent_folder_id: None,
                    };
                    created.push(folder.id.clone());
                    manifest.folders.push(folder);
                }
            }
            if let Some(renames) = array(map, "renames")? {
                for rename in renames {
                    let rename = object(rename)?;
                    let id = required_string(rename, "id")?;
                    let name = required_string(rename, "name")?;
                    let entry = manifest
                        .entries
                        .iter_mut()
                        .find(|entry| entry.id == id)
                        .ok_or_else(|| BackendError::message(format!("media not found: {id}")))?;
                    entry.name = name;
                }
            }
            if let Some(moves) = array(map, "moves")? {
                for item in moves {
                    let item = object(item)?;
                    let id = required_string(item, "id")?;
                    let folder_id = string(item, "folderId")?;
                    let entry = manifest
                        .entries
                        .iter_mut()
                        .find(|entry| entry.id == id)
                        .ok_or_else(|| BackendError::message(format!("media not found: {id}")))?;
                    entry.folder_id = folder_id;
                }
            }
            if let Some(deletes) = array(map, "deletes")? {
                for id in deletes {
                    let id = id
                        .as_str()
                        .ok_or_else(|| BackendError::message("delete ids must be strings"))?;
                    let referenced = view.snapshot.project.timelines.iter().any(|timeline| {
                        timeline
                            .tracks
                            .iter()
                            .flat_map(|track| &track.clips)
                            .any(|clip| clip.media_ref == id)
                    });
                    if referenced {
                        return Err(BackendError::message(format!(
                            "media {id} is still used by a timeline"
                        )));
                    }
                    manifest.entries.retain(|entry| entry.id != id);
                }
            }
            let result = self
                .commit_value(
                    &view,
                    EditorCommand::UpdateMediaManifest {
                        timeline_id,
                        media_manifest: manifest,
                    },
                )
                .await?;
            Ok(json!({"receipt": result, "createdFolderIds": created}))
        })
    }

    fn capture_frame(&self, _args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async {
            Err(BackendError::message(
                "capture_frame requires the media-enabled application backend",
            ))
        })
    }

    fn execute(&self, command: EditorCommand) -> BoxFut<'_, BackendResult<MutationReceipt>> {
        Box::pin(async move {
            let view = self.active_view().await?;
            Ok(self
                .editor
                .commit_edit(view.summary.project_id, view.summary.revision, command)
                .await
                .map_err(service_error)?
                .receipt)
        })
    }

    fn add_clips(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let map = object(&args)?;
            let entries = required_array(map, "entries")?;
            if entries.is_empty() {
                return Err(BackendError::message("entries must not be empty"));
            }
            let view = self.active_view().await?;
            let timeline = Self::active_timeline(&view)?;
            let mut commands = Vec::new();
            for value in entries {
                let entry = object(value)?;
                let media_ref = required_string(entry, "mediaRef")?;
                let media = view
                    .snapshot
                    .media_manifest
                    .entries
                    .iter()
                    .find(|candidate| candidate.id == media_ref)
                    .ok_or_else(|| BackendError::message(format!("media not found: {media_ref}")))?;
                let start = required_integer(entry, "startFrame")?;
                let end = integer(entry, "endFrame")?;
                let duration = end
                    .map(|end| end - start)
                    .unwrap_or_else(|| media_duration_frames(media.duration, timeline.fps));
                if duration <= 0 {
                    return Err(BackendError::message("clip duration must be positive"));
                }
                let track_index = integer(entry, "trackIndex")?
                    .map(|value| usize::try_from(value).unwrap_or(usize::MAX));
                let track = select_track(timeline, media.media_type, track_index)?;
                let mut clip = Clip::new(media_ref, start, duration);
                clip.media_type = media.media_type;
                clip.source_clip_type = media.media_type;
                commands.push(EditorCommand::AddClips {
                    timeline_id: timeline.id.clone(),
                    track_id: track.id.clone(),
                    start_frame: start,
                    clips: vec![clip],
                    mode: AddMode::Overwrite,
                });
            }
            self.commit_value(
                &view,
                EditorCommand::Batch {
                    timeline_id: timeline.id.clone(),
                    commands,
                },
            )
            .await
        })
    }

    fn insert_clips(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let map = object(&args)?;
            let view = self.active_view().await?;
            let timeline = Self::active_timeline(&view)?;
            let track_index = usize::try_from(required_integer(map, "trackIndex")?)
                .map_err(|_| BackendError::message("trackIndex is out of range"))?;
            let track = timeline
                .tracks
                .get(track_index)
                .ok_or_else(|| BackendError::message("trackIndex is out of range"))?;
            let mut cursor = required_integer(map, "atFrame")?;
            let mut commands = Vec::new();
            for value in required_array(map, "entries")? {
                let entry = object(value)?;
                let media_ref = required_string(entry, "mediaRef")?;
                let media = view
                    .snapshot
                    .media_manifest
                    .entries
                    .iter()
                    .find(|candidate| candidate.id == media_ref)
                    .ok_or_else(|| BackendError::message(format!("media not found: {media_ref}")))?;
                let duration = integer(entry, "durationFrames")?
                    .unwrap_or_else(|| media_duration_frames(media.duration, timeline.fps));
                let mut clip = Clip::new(media_ref, cursor, duration);
                clip.media_type = media.media_type;
                clip.source_clip_type = media.media_type;
                commands.push(EditorCommand::AddClips {
                    timeline_id: timeline.id.clone(),
                    track_id: track.id.clone(),
                    start_frame: cursor,
                    clips: vec![clip],
                    mode: AddMode::Ripple,
                });
                cursor = cursor.saturating_add(duration);
            }
            self.commit_value(
                &view,
                EditorCommand::Batch {
                    timeline_id: timeline.id.clone(),
                    commands,
                },
            )
            .await
        })
    }

    fn move_clips(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let view = self.active_view().await?;
            let timeline = Self::active_timeline(&view)?;
            let mut moves = Vec::new();
            for value in required_array(object(&args)?, "moves")? {
                let item = object(value)?;
                let clip_id = required_string(item, "clipId")?;
                let location = timeline
                    .clip_location(&clip_id)
                    .ok_or_else(|| BackendError::message(format!("clip not found: {clip_id}")))?;
                let current_track = &timeline.tracks[location.track_index];
                let track_id = match integer(item, "toTrack")? {
                    Some(index) => timeline
                        .tracks
                        .get(usize::try_from(index).unwrap_or(usize::MAX))
                        .ok_or_else(|| BackendError::message("toTrack is out of range"))?
                        .id
                        .clone(),
                    None => current_track.id.clone(),
                };
                let start_frame = integer(item, "toFrame")?
                    .unwrap_or(current_track.clips[location.clip_index].start_frame);
                moves.push(MoveClipRequest {
                    clip_id,
                    track_id,
                    start_frame,
                });
            }
            self.commit_value(
                &view,
                EditorCommand::MoveClips {
                    timeline_id: timeline.id.clone(),
                    moves,
                },
            )
            .await
        })
    }

    fn remove_clips(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let view = self.active_view().await?;
            let timeline = Self::active_timeline(&view)?;
            let clip_ids = string_array(object(&args)?, "clipIds")?;
            self.commit_value(
                &view,
                EditorCommand::RemoveClips {
                    timeline_id: timeline.id.clone(),
                    clip_ids,
                    prune_empty_tracks: false,
                },
            )
            .await
        })
    }

    fn split_clips(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let map = object(&args)?;
            let view = self.active_view().await?;
            let timeline = Self::active_timeline(&view)?;
            let splits = required_array(map, "splits")?;
            let mut commands = Vec::new();
            for value in splits {
                let split = object(value)?;
                commands.push(EditorCommand::SplitClip {
                    timeline_id: timeline.id.clone(),
                    clip_id: required_string(split, "clipId")?,
                    at_frame: required_integer(split, "atFrame")?,
                });
            }
            self.commit_value(
                &view,
                EditorCommand::Batch {
                    timeline_id: timeline.id.clone(),
                    commands,
                },
            )
            .await
        })
    }

    fn ripple_delete_ranges(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let map = object(&args)?;
            let view = self.active_view().await?;
            let timeline = Self::active_timeline(&view)?;
            let track_index = usize::try_from(required_integer(map, "trackIndex")?)
                .map_err(|_| BackendError::message("trackIndex is out of range"))?;
            let track = timeline
                .tracks
                .get(track_index)
                .ok_or_else(|| BackendError::message("trackIndex is out of range"))?;
            let mut ranges = Vec::new();
            for value in required_array(map, "ranges")? {
                let pair = value
                    .as_array()
                    .filter(|pair| pair.len() == 2)
                    .ok_or_else(|| BackendError::message("ranges must contain [start, end]"))?;
                ranges.push(FrameRange {
                    start: pair[0]
                        .as_i64()
                        .ok_or_else(|| BackendError::message("range start must be an integer"))?,
                    end: pair[1]
                        .as_i64()
                        .ok_or_else(|| BackendError::message("range end must be an integer"))?,
                });
            }
            self.commit_value(
                &view,
                EditorCommand::RippleDelete {
                    timeline_id: timeline.id.clone(),
                    track_id: track.id.clone(),
                    ranges,
                    ignored_sync_locked_track_ids: Vec::new(),
                },
            )
            .await
        })
    }

    fn manage_clip_links(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let map = object(&args)?;
            let view = self.active_view().await?;
            let timeline_id = Self::active_timeline(&view)?.id.clone();
            let clip_ids = string_array(map, "clipIds")?;
            let command = match required_string(map, "action")?.as_str() {
                "link" => EditorCommand::LinkClips {
                    timeline_id,
                    clip_ids,
                },
                "unlink" => EditorCommand::UnlinkClips {
                    timeline_id,
                    clip_ids,
                },
                other => return Err(BackendError::message(format!("unsupported action: {other}"))),
            };
            self.commit_value(&view, command).await
        })
    }

    fn manage_tracks(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let map = object(&args)?;
            let view = self.active_view().await?;
            let timeline = Self::active_timeline(&view)?;
            let mut commands = Vec::new();
            if let Some(items) = array(map, "reorder")? {
                for value in items {
                    let item = object(value)?;
                    commands.push(EditorCommand::ReorderTrack {
                        timeline_id: timeline.id.clone(),
                        track_id: track_id(timeline, item)?,
                        target_index: usize::try_from(required_integer(item, "to")?)
                            .map_err(|_| BackendError::message("to is out of range"))?,
                    });
                }
            }
            if let Some(items) = array(map, "set")? {
                for value in items {
                    let item = object(value)?;
                    commands.push(EditorCommand::UpdateTrack {
                        timeline_id: timeline.id.clone(),
                        track_id: track_id(timeline, item)?,
                        patch: TrackPatch {
                            muted: boolean(item, "muted")?,
                            hidden: boolean(item, "hidden")?,
                            sync_locked: boolean(item, "syncLocked")?,
                            display_height: None,
                        },
                    });
                }
            }
            if let Some(items) = array(map, "remove")? {
                let mut ids = Vec::new();
                for value in items {
                    if let Some(index) = value.as_i64() {
                        ids.push(
                            timeline
                                .tracks
                                .get(usize::try_from(index).unwrap_or(usize::MAX))
                                .ok_or_else(|| BackendError::message("track index is out of range"))?
                                .id
                                .clone(),
                        );
                    } else {
                        ids.push(required_string(object(value)?, "trackId")?);
                    }
                }
                commands.push(EditorCommand::RemoveTracks {
                    timeline_id: timeline.id.clone(),
                    track_ids: ids,
                });
            }
            self.commit_value(
                &view,
                EditorCommand::Batch {
                    timeline_id: timeline.id.clone(),
                    commands,
                },
            )
            .await
        })
    }

    fn set_clip_properties(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let map = object(&args)?;
            let view = self.active_view().await?;
            let timeline = Self::active_timeline(&view)?;
            let ids = string_array(map, "clipIds")?;
            let mut clips = selected_clips(timeline, &ids)?;
            for clip in &mut clips {
                if let Some(value) = integer(map, "durationFrames")? {
                    clip.set_duration(value);
                }
                if let Some(value) = integer(map, "trimStartFrame")? {
                    clip.trim_start_frame = value;
                }
                if let Some(value) = integer(map, "trimEndFrame")? {
                    clip.trim_end_frame = value;
                }
                if let Some(value) = number(map, "speed")? {
                    clip.speed = value;
                }
                if let Some(value) = number(map, "volumeDb")? {
                    clip.volume = 10_f64.powf(value / 20.0);
                    clip.volume_track = None;
                }
                if let Some(value) = number(map, "opacity")? {
                    clip.opacity = value;
                    clip.opacity_track = None;
                }
                if let Some(value) = integer(map, "fadeInFrames")? {
                    clip.fade_in_frames = value;
                }
                if let Some(value) = integer(map, "fadeOutFrames")? {
                    clip.fade_out_frames = value;
                }
                if let Some(value) = number(map, "edgeRounding")? {
                    clip.edge_rounding = value;
                }
                if let Some(value) = number(map, "edgeSoftness")? {
                    clip.edge_softness = value;
                }
                if let Some(transform) = map.get("transform") {
                    apply_transform_patch(clip, object(transform)?)?;
                }
            }
            self.commit_value(
                &view,
                EditorCommand::UpdateClips {
                    timeline_id: timeline.id.clone(),
                    clips,
                },
            )
            .await
        })
    }

    fn add_texts(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let view = self.active_view().await?;
            let timeline = Self::active_timeline(&view)?;
            let track = timeline
                .tracks
                .iter()
                .find(|track| track.track_type.is_visual())
                .ok_or_else(|| BackendError::message("timeline has no visual track"))?;
            let mut commands = Vec::new();
            for value in required_array(object(&args)?, "entries")? {
                let entry = object(value)?;
                let start = required_integer(entry, "startFrame")?;
                let end = integer(entry, "endFrame")?.unwrap_or(start + i64::from(timeline.fps) * 3);
                let mut clip = Clip::new("", start, end - start);
                clip.media_type = ClipType::Text;
                clip.source_clip_type = ClipType::Text;
                clip.text_content = Some(required_string(entry, "content")?);
                clip.text_style = Some(TextStyle::default());
                commands.push(EditorCommand::AddClips {
                    timeline_id: timeline.id.clone(),
                    track_id: track.id.clone(),
                    start_frame: start,
                    clips: vec![clip],
                    mode: AddMode::Overwrite,
                });
            }
            self.commit_value(
                &view,
                EditorCommand::Batch {
                    timeline_id: timeline.id.clone(),
                    commands,
                },
            )
            .await
        })
    }

    fn update_text(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let map = object(&args)?;
            let view = self.active_view().await?;
            let timeline = Self::active_timeline(&view)?;
            let ids = string_array(map, "clipIds")?;
            let content = string(map, "content")?;
            let mut clips = selected_clips(timeline, &ids)?;
            for clip in &mut clips {
                if clip.media_type != ClipType::Text {
                    return Err(BackendError::message(format!(
                        "clip {} is not text",
                        clip.id
                    )));
                }
                if let Some(content) = &content {
                    clip.text_content = Some(content.clone());
                }
                if let Some(transform) = map.get("transform") {
                    apply_transform_patch(clip, object(transform)?)?;
                }
            }
            self.commit_value(
                &view,
                EditorCommand::UpdateClips {
                    timeline_id: timeline.id.clone(),
                    clips,
                },
            )
            .await
        })
    }

    fn apply_color(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let map = object(&args)?;
            let view = self.active_view().await?;
            let timeline = Self::active_timeline(&view)?;
            let ids = string_array(map, "clipIds")?;
            let mut clips = selected_clips(timeline, &ids)?;
            for clip in &mut clips {
                let mut effects = clip.effects.clone().unwrap_or_default();
                effects.retain(|effect| !effect.effect_type.starts_with("color."));
                if !boolean(map, "reset")?.unwrap_or(false) {
                    let mut effect = Effect::new("color.grade");
                    for key in [
                        "exposure",
                        "contrast",
                        "saturation",
                        "temperature",
                        "tint",
                        "highlights",
                        "shadows",
                    ] {
                        if let Some(value) = number(map, key)? {
                            effect.params.insert(
                                key.into(),
                                EffectParam {
                                    value: Some(value),
                                    string: None,
                                    track: None,
                                },
                            );
                        }
                    }
                    if !effect.params.is_empty() {
                        effects.push(effect);
                    }
                }
                clip.effects = (!effects.is_empty()).then_some(effects);
            }
            self.commit_value(
                &view,
                EditorCommand::UpdateClips {
                    timeline_id: timeline.id.clone(),
                    clips,
                },
            )
            .await
        })
    }

    fn apply_effect(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let map = object(&args)?;
            let view = self.active_view().await?;
            let timeline = Self::active_timeline(&view)?;
            let ids = string_array(map, "clipIds")?;
            let remove = array(map, "remove")?
                .map(|items| {
                    items
                        .iter()
                        .filter_map(Value::as_str)
                        .collect::<HashSet<_>>()
                })
                .unwrap_or_default();
            let additions = array(map, "effects")?.cloned().unwrap_or_default();
            let mut clips = selected_clips(timeline, &ids)?;
            for clip in &mut clips {
                let mut effects = clip.effects.clone().unwrap_or_default();
                effects.retain(|effect| !remove.contains(effect.effect_type.as_str()));
                for value in &additions {
                    let value = object(value)?;
                    let effect_type = required_string(value, "type")?;
                    let mut effect = Effect::new(effect_type.clone());
                    effect.enabled = boolean(value, "enabled")?.unwrap_or(true);
                    if let Some(params) = value.get("params").and_then(Value::as_object) {
                        for (key, value) in params {
                            if let Some(value) = value.as_f64() {
                                effect.params.insert(
                                    key.clone(),
                                    EffectParam {
                                        value: Some(value),
                                        string: None,
                                        track: None,
                                    },
                                );
                            }
                        }
                    }
                    effects.retain(|existing| existing.effect_type != effect_type);
                    effects.push(effect);
                }
                clip.effects = (!effects.is_empty()).then_some(effects);
            }
            self.commit_value(
                &view,
                EditorCommand::UpdateClips {
                    timeline_id: timeline.id.clone(),
                    clips,
                },
            )
            .await
        })
    }

    fn export_project(&self, _args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async {
            Err(BackendError::message(
                "export_project requires the media-enabled application backend",
            ))
        })
    }

    fn manage_exports(&self, _args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async {
            Err(BackendError::message(
                "manage_exports requires the media-enabled application backend",
            ))
        })
    }

    fn list_models(&self, _args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let models = list_models(self.generation()?)
                .await
                .map_err(generation_error)?;
            Ok(json!({"models": models}))
        })
    }

    fn generate_video(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let params: GenerateVideoParams =
                serde_json::from_value(args).map_err(json_error)?;
            let job = generate_video(self.generation()?, params)
                .await
                .map_err(generation_error)?;
            serde_json::to_value(job).map_err(json_error)
        })
    }

    fn generate_image(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let params: GenerateImageParams =
                serde_json::from_value(args).map_err(json_error)?;
            let job = generate_image(self.generation()?, params)
                .await
                .map_err(generation_error)?;
            serde_json::to_value(job).map_err(json_error)
        })
    }

    fn generate_audio(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let params: GenerateAudioParams =
                serde_json::from_value(args).map_err(json_error)?;
            let job = generate_audio(self.generation()?, params)
                .await
                .map_err(generation_error)?;
            serde_json::to_value(job).map_err(json_error)
        })
    }

    fn upscale_media(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let params: UpscaleMediaParams =
                serde_json::from_value(args).map_err(json_error)?;
            let job = upscale_media(self.generation()?, params)
                .await
                .map_err(generation_error)?;
            serde_json::to_value(job).map_err(json_error)
        })
    }

    fn undo(&self, _args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let view = self.active_view().await?;
            self.commit_value(&view, EditorCommand::Undo).await
        })
    }
}

fn service_error(error: palmier_service::ServiceError) -> BackendError {
    BackendError::message(error.to_string())
}

fn json_error(error: serde_json::Error) -> BackendError {
    BackendError::message(error.to_string())
}

fn generation_error(error: palmier_generation::GenerationError) -> BackendError {
    BackendError::message(error.to_string())
}

fn object(value: &Value) -> BackendResult<&Map<String, Value>> {
    value
        .as_object()
        .ok_or_else(|| BackendError::message("value must be an object"))
}

fn string(map: &Map<String, Value>, key: &str) -> BackendResult<Option<String>> {
    match map.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(_) => Err(BackendError::message(format!("{key} must be a string"))),
    }
}

fn required_string(map: &Map<String, Value>, key: &str) -> BackendResult<String> {
    string(map, key)?.ok_or_else(|| BackendError::message(format!("{key} is required")))
}

fn integer(map: &Map<String, Value>, key: &str) -> BackendResult<Option<i64>> {
    match map.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => value
            .as_i64()
            .map(Some)
            .ok_or_else(|| BackendError::message(format!("{key} must be an integer"))),
        Some(_) => Err(BackendError::message(format!("{key} must be an integer"))),
    }
}

fn required_integer(map: &Map<String, Value>, key: &str) -> BackendResult<i64> {
    integer(map, key)?.ok_or_else(|| BackendError::message(format!("{key} is required")))
}

fn number(map: &Map<String, Value>, key: &str) -> BackendResult<Option<f64>> {
    match map.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => value
            .as_f64()
            .filter(|value| value.is_finite())
            .map(Some)
            .ok_or_else(|| BackendError::message(format!("{key} must be finite"))),
        Some(_) => Err(BackendError::message(format!("{key} must be a number"))),
    }
}

fn boolean(map: &Map<String, Value>, key: &str) -> BackendResult<Option<bool>> {
    match map.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(BackendError::message(format!("{key} must be a boolean"))),
    }
}

fn array<'a>(map: &'a Map<String, Value>, key: &str) -> BackendResult<Option<&'a Vec<Value>>> {
    match map.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Array(value)) => Ok(Some(value)),
        Some(_) => Err(BackendError::message(format!("{key} must be an array"))),
    }
}

fn required_array<'a>(map: &'a Map<String, Value>, key: &str) -> BackendResult<&'a Vec<Value>> {
    array(map, key)?.ok_or_else(|| BackendError::message(format!("{key} is required")))
}

fn string_array(map: &Map<String, Value>, key: &str) -> BackendResult<Vec<String>> {
    required_array(map, key)?
        .iter()
        .map(|value| {
            value
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| BackendError::message(format!("{key} must contain strings")))
        })
        .collect()
}

fn media_duration_frames(duration: f64, fps: i32) -> i64 {
    if duration.is_finite() && duration > 0.0 && fps > 0 {
        (duration * f64::from(fps)).round().max(1.0) as i64
    } else {
        i64::from(fps.max(1)) * 5
    }
}

fn select_track(
    timeline: &Timeline,
    clip_type: ClipType,
    requested: Option<usize>,
) -> BackendResult<&palmier_core::Track> {
    if let Some(index) = requested {
        return timeline
            .tracks
            .get(index)
            .filter(|track| track.track_type.is_compatible_with(clip_type))
            .ok_or_else(|| BackendError::message("trackIndex is missing or incompatible"));
    }
    timeline
        .tracks
        .iter()
        .find(|track| track.track_type.is_compatible_with(clip_type))
        .ok_or_else(|| BackendError::message("timeline has no compatible track"))
}

fn track_id(timeline: &Timeline, map: &Map<String, Value>) -> BackendResult<String> {
    if let Some(id) = string(map, "trackId")? {
        return Ok(id);
    }
    let index = usize::try_from(required_integer(map, "index")?)
        .map_err(|_| BackendError::message("track index is out of range"))?;
    timeline
        .tracks
        .get(index)
        .map(|track| track.id.clone())
        .ok_or_else(|| BackendError::message("track index is out of range"))
}

fn selected_clips(timeline: &Timeline, ids: &[String]) -> BackendResult<Vec<Clip>> {
    let clips = timeline
        .tracks
        .iter()
        .flat_map(|track| &track.clips)
        .filter(|clip| ids.contains(&clip.id))
        .cloned()
        .collect::<Vec<_>>();
    if clips.len() != ids.len() {
        return Err(BackendError::message("one or more clip ids were not found"));
    }
    Ok(clips)
}

fn apply_transform_patch(clip: &mut Clip, map: &Map<String, Value>) -> BackendResult<()> {
    if let Some(value) = number(map, "centerX")? {
        clip.transform.center_x = value;
        clip.position_track = None;
    }
    if let Some(value) = number(map, "centerY")? {
        clip.transform.center_y = value;
        clip.position_track = None;
    }
    if let Some(value) = number(map, "width")? {
        clip.transform.width = value;
        clip.scale_track = None;
    }
    if let Some(value) = number(map, "height")? {
        clip.transform.height = value;
        clip.scale_track = None;
    }
    if let Some(value) = number(map, "rotation")? {
        clip.transform.rotation = value;
        clip.rotation_track = None;
    }
    Ok(())
}
