use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;

use palmier_core::{
    AddMode, Clip, ClipType, EditorCommand, EditorSession, Effect, EffectParam, FrameRange,
    MediaManifest, MediaManifestEntry, MediaSource, MoveClipRequest, MutationReceipt,
    MutationStatus, ProjectFile, TextStyle, Timeline, Track, TrackPatch, new_id,
};
use serde_json::{Value, json};
use tokio::sync::Mutex;

use crate::backend::{
    BoxFut, CreateProjectRequest, McpEditorBackend, ProjectSelector, SharedBackend,
};
use crate::error::{BackendError, BackendResult};
use crate::json_util::{
    decode_field, optional_array, optional_bool, optional_f64, optional_i64, optional_string,
    reject_unknown_keys, require_array, require_i64, require_object, require_string,
};

#[derive(Debug, Clone)]
struct StoredProject {
    id: String,
    name: String,
    path: Option<PathBuf>,
    session: EditorSession,
}

#[derive(Debug, Clone)]
struct ExportJob {
    job_id: String,
    filename: String,
    path: String,
    status: String,
    progress: f64,
    mode: String,
}

#[derive(Default)]
struct MemoryState {
    projects: HashMap<String, StoredProject>,
    active_project_id: Option<String>,
    exports: Vec<ExportJob>,
}

/// Test and standalone backend that drives `palmier-core::EditorSession` directly.
pub struct InMemoryEditorBackend {
    state: Mutex<MemoryState>,
}

impl InMemoryEditorBackend {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(MemoryState::default()),
        }
    }

    pub fn shared() -> SharedBackend {
        Arc::new(Self::new())
    }

    fn resolve_quality(quality: Option<&str>, aspect: (i32, i32)) -> BackendResult<(i32, i32)> {
        let short = match quality.unwrap_or("1080p") {
            "720p" => 720,
            "1080p" => 1080,
            "2K" => 1440,
            "4K" => 2160,
            other => {
                return Err(BackendError::message(format!(
                    "unsupported quality '{other}'"
                )));
            }
        };
        let (aw, ah) = aspect;
        if aw >= ah {
            let height = short;
            let width = ((f64::from(height) * f64::from(aw) / f64::from(ah)).round() as i32).max(2);
            Ok((width + width % 2, height))
        } else {
            let width = short;
            let height = ((f64::from(width) * f64::from(ah) / f64::from(aw)).round() as i32).max(2);
            Ok((width, height + height % 2))
        }
    }

    fn parse_aspect(value: Option<&str>) -> BackendResult<(i32, i32)> {
        let raw = value.unwrap_or("16:9");
        let mut parts = raw.split(':');
        let width = parts
            .next()
            .and_then(|part| part.parse::<f64>().ok())
            .ok_or_else(|| BackendError::message(format!("invalid aspectRatio '{raw}'")))?;
        let height = parts
            .next()
            .and_then(|part| part.parse::<f64>().ok())
            .ok_or_else(|| BackendError::message(format!("invalid aspectRatio '{raw}'")))?;
        if parts.next().is_some() || width <= 0.0 || height <= 0.0 {
            return Err(BackendError::message(format!(
                "invalid aspectRatio '{raw}'"
            )));
        }
        Ok((width.round() as i32, height.round() as i32))
    }

    fn project_summary(project: &StoredProject, active: bool) -> Value {
        json!({
            "id": project.id,
            "name": project.name,
            "path": project.path.as_ref().map(|path| path.display().to_string()),
            "active": active,
            "visible": active,
        })
    }

    fn find_project_id(state: &MemoryState, selector: &ProjectSelector) -> BackendResult<String> {
        if let Some(id) = &selector.id {
            if state.projects.contains_key(id) {
                return Ok(id.clone());
            }
            return Err(BackendError::message(format!(
                "project id '{id}' not found"
            )));
        }
        if let Some(path) = &selector.path {
            let needle = PathBuf::from(path);
            if let Some(project) = state
                .projects
                .values()
                .find(|project| project.path.as_ref() == Some(&needle))
            {
                return Ok(project.id.clone());
            }
            return Err(BackendError::message(format!(
                "project path '{path}' not found"
            )));
        }
        if let Some(name) = &selector.name {
            let lowered = name.to_ascii_lowercase();
            let matches: Vec<&StoredProject> = state
                .projects
                .values()
                .filter(|project| project.name.to_ascii_lowercase() == lowered)
                .collect();
            return match matches.as_slice() {
                [only] => Ok(only.id.clone()),
                [] => Err(BackendError::message(format!(
                    "project name '{name}' not found"
                ))),
                _ => Err(BackendError::message(format!(
                    "project name '{name}' is ambiguous"
                ))),
            };
        }
        state
            .active_project_id
            .clone()
            .ok_or(BackendError::InactiveProject)
    }

    fn active_mut(state: &mut MemoryState) -> BackendResult<&mut StoredProject> {
        let id = state
            .active_project_id
            .clone()
            .ok_or(BackendError::InactiveProject)?;
        state
            .projects
            .get_mut(&id)
            .ok_or(BackendError::InactiveProject)
    }

    fn active_ref(state: &MemoryState) -> BackendResult<&StoredProject> {
        let id = state
            .active_project_id
            .as_ref()
            .ok_or(BackendError::InactiveProject)?;
        state.projects.get(id).ok_or(BackendError::InactiveProject)
    }

    fn collect_ids(session: &EditorSession) -> HashSet<String> {
        let mut ids = HashSet::new();
        let project = session.project();
        for timeline in &project.timelines {
            ids.insert(timeline.id.clone());
            for track in &timeline.tracks {
                ids.insert(track.id.clone());
                for clip in &track.clips {
                    ids.insert(clip.id.clone());
                    if let Some(group) = &clip.caption_group_id {
                        ids.insert(group.clone());
                    }
                    if let Some(group) = &clip.link_group_id {
                        ids.insert(group.clone());
                    }
                    if !clip.media_ref.is_empty() {
                        ids.insert(clip.media_ref.clone());
                    }
                }
            }
        }
        for entry in &session.media_manifest().entries {
            ids.insert(entry.id.clone());
        }
        ids
    }

    fn active_timeline<'a>(session: &'a EditorSession) -> BackendResult<&'a Timeline> {
        let project = session.project();
        let id = project
            .active_timeline_id()
            .ok_or_else(|| BackendError::message("project has no active timeline"))?;
        project
            .timelines
            .iter()
            .find(|timeline| timeline.id == id)
            .ok_or_else(|| BackendError::message("active timeline missing"))
    }

    fn replace_session(
        project: &mut StoredProject,
        mut next_project: ProjectFile,
        next_manifest: MediaManifest,
    ) -> BackendResult<()> {
        next_project.normalize_navigation();
        project.session = EditorSession::with_manifest(next_project, next_manifest)?;
        Ok(())
    }

    fn receipt_json(receipt: &MutationReceipt) -> Value {
        serde_json::to_value(receipt).unwrap_or_else(|_| json!({}))
    }

    fn media_entry_json(entry: &MediaManifestEntry) -> Value {
        let mut value = json!({
            "id": entry.id,
            "name": entry.name,
            "type": entry.media_type,
            "durationSeconds": entry.duration,
        });
        if let Some(width) = entry.source_width {
            value["width"] = json!(width);
        }
        if let Some(height) = entry.source_height {
            value["height"] = json!(height);
        }
        if let Some(fps) = entry.source_fps {
            value["fps"] = json!(fps);
        }
        if let Some(has_audio) = entry.has_audio {
            value["hasAudio"] = json!(has_audio);
        }
        if let Some(status) = &entry.generation_status {
            value["generationStatus"] = json!(status);
        }
        value
    }

    fn ensure_track(
        session: &mut EditorSession,
        timeline_id: &str,
        track_type: ClipType,
        track_index: Option<usize>,
    ) -> BackendResult<String> {
        let timeline = Self::active_timeline(session)?;
        if let Some(index) = track_index {
            let track = timeline.tracks.get(index).ok_or_else(|| {
                BackendError::message(format!("trackIndex {index} is out of range"))
            })?;
            if !track.track_type.is_compatible_with(track_type)
                && !(track.track_type.is_visual() && track_type.is_visual())
            {
                return Err(BackendError::message(format!(
                    "trackIndex {index} is incompatible with {:?}",
                    track_type
                )));
            }
            return Ok(track.id.clone());
        }
        if let Some(existing) = timeline
            .tracks
            .iter()
            .find(|track| track.track_type == track_type)
        {
            return Ok(existing.id.clone());
        }
        let requested_index = timeline.tracks.len();
        let receipt = session.execute(EditorCommand::AddTrack {
            timeline_id: timeline_id.to_owned(),
            track_type,
            requested_index,
        })?;
        receipt
            .created_track_ids
            .first()
            .cloned()
            .ok_or_else(|| BackendError::message("failed to create track"))
    }

    fn clip_from_media(
        entry: &MediaManifestEntry,
        start_frame: i64,
        duration_frames: i64,
        trim_start: i64,
        trim_end: i64,
    ) -> Clip {
        let mut clip = Clip::new(entry.id.clone(), start_frame, duration_frames);
        clip.media_type = entry.media_type;
        clip.source_clip_type = entry.media_type;
        clip.trim_start_frame = trim_start;
        clip.trim_end_frame = trim_end;
        clip
    }

    fn resolve_media<'a>(
        session: &'a EditorSession,
        media_ref: &str,
    ) -> BackendResult<&'a MediaManifestEntry> {
        session
            .media_manifest()
            .entries
            .iter()
            .find(|entry| entry.id == media_ref)
            .ok_or_else(|| {
                BackendError::message(format!(
                    "mediaRef '{media_ref}' not found. Call get_media first."
                ))
            })
    }

    fn timeline_payload(session: &EditorSession, args: &Value) -> BackendResult<Value> {
        let map = require_object(args)?;
        reject_unknown_keys(
            map,
            &["startFrame", "endFrame", "captionDetail"],
            "get_timeline",
        )?;
        let start = optional_i64(map, "startFrame")?;
        let end = optional_i64(map, "endFrame")?;
        let caption_detail = optional_bool(map, "captionDetail")?.unwrap_or(false);
        let timeline = Self::active_timeline(session)?;
        let total_frames = timeline.total_frames();
        let window = match (start, end) {
            (None, None) => None,
            (Some(s), Some(e)) if s < e => Some((s, e)),
            (Some(s), None) => Some((s, i64::MAX)),
            (None, Some(e)) if e > 0 => Some((0, e)),
            _ => {
                return Err(BackendError::message(
                    "Invalid window: startFrame must be less than endFrame",
                ));
            }
        };

        let mut tracks = Vec::new();
        for (index, track) in timeline.tracks.iter().enumerate() {
            let mut clips = Vec::new();
            let mut hidden = 0_usize;
            for clip in &track.clips {
                let clip_end = clip.end_frame();
                if let Some((window_start, window_end)) = window {
                    if clip_end <= window_start || clip.start_frame >= window_end {
                        hidden += 1;
                        continue;
                    }
                }
                if clip.caption_group_id.is_some() && !caption_detail {
                    continue;
                }
                let mut item = json!({
                    "id": clip.id,
                    "mediaRef": clip.media_ref,
                    "startFrame": clip.start_frame,
                    "durationFrames": clip.duration_frames,
                    "end": clip_end,
                });
                if clip.media_type != ClipType::Video {
                    item["mediaType"] = json!(clip.media_type);
                }
                if (clip.speed - 1.0).abs() > f64::EPSILON {
                    item["speed"] = json!(clip.speed);
                }
                if let Some(text) = &clip.text_content {
                    item["text"] = json!(text);
                }
                if let Some(effects) = &clip.effects {
                    item["effects"] = serde_json::to_value(effects).unwrap_or(json!([]));
                }
                clips.push(item);
            }
            let mut track_json = json!({
                "trackId": track.id,
                "index": index,
                "type": track.track_type,
                "clips": clips,
            });
            if track.muted {
                track_json["muted"] = json!(true);
            }
            if track.hidden {
                track_json["hidden"] = json!(true);
            }
            if !track.sync_locked {
                track_json["syncLocked"] = json!(false);
            }
            if hidden > 0 {
                track_json["totalClips"] = json!(track.clips.len());
            }
            tracks.push(track_json);
        }

        let mut payload = json!({
            "timelineId": timeline.id,
            "name": timeline.name,
            "fps": timeline.fps,
            "width": timeline.width,
            "height": timeline.height,
            "totalFrames": total_frames,
            "durationSeconds": total_frames as f64 / f64::from(timeline.fps.max(1)),
            "tracks": tracks,
            "canGenerate": false,
        });
        if let Some((start_frame, end_frame)) = window {
            payload["window"] = json!([start_frame, end_frame.min(total_frames)]);
        }
        if session.project().timelines.len() > 1 {
            payload["timelines"] = json!(
                session
                    .project()
                    .timelines
                    .iter()
                    .map(|timeline| {
                        let mut entry = json!({
                            "timelineId": timeline.id,
                            "name": timeline.name,
                        });
                        if Some(timeline.id.as_str()) == session.project().active_timeline_id() {
                            entry["active"] = json!(true);
                        }
                        entry
                    })
                    .collect::<Vec<_>>()
            );
        }
        Ok(payload)
    }
}

impl Default for InMemoryEditorBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl McpEditorBackend for InMemoryEditorBackend {
    fn list_projects(&self) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let state = self.state.lock().await;
            let projects: Vec<Value> = state
                .projects
                .values()
                .map(|project| {
                    let active = state.active_project_id.as_deref() == Some(project.id.as_str());
                    Self::project_summary(project, active)
                })
                .collect();
            Ok(json!({
                "projects": projects,
                "activeProjectId": state.active_project_id,
            }))
        })
    }

    fn open_project(&self, request: ProjectSelector) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let id = Self::find_project_id(&state, &request)?;
            state.active_project_id = Some(id.clone());
            let project = state.projects.get(&id).expect("project exists");
            Ok(Self::project_summary(project, true))
        })
    }

    fn create_project(&self, request: CreateProjectRequest) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let name = request
                .name
                .unwrap_or_else(|| "Untitled Project".to_owned());
            let fps = request.fps.unwrap_or(30);
            if !(1..=120).contains(&fps) {
                return Err(BackendError::message("fps must be between 1 and 120"));
            }
            let aspect = Self::parse_aspect(request.aspect_ratio.as_deref())?;
            let (width, height) = Self::resolve_quality(request.quality.as_deref(), aspect)?;
            let mut timeline = Timeline::default();
            timeline.name = "Timeline 1".to_owned();
            timeline.fps = fps;
            timeline.width = width;
            timeline.height = height;
            timeline.settings_configured = true;
            timeline.tracks = vec![Track::new(ClipType::Video), Track::new(ClipType::Audio)];
            let project_file = ProjectFile::new(vec![timeline])
                .map_err(|error| BackendError::message(error.to_string()))?;
            let session = EditorSession::new(project_file)?;
            let id = new_id();
            let stored = StoredProject {
                id: id.clone(),
                name,
                path: None,
                session,
            };
            let summary = Self::project_summary(&stored, true);
            state.projects.insert(id.clone(), stored);
            state.active_project_id = Some(id);
            Ok(summary)
        })
    }

    fn close_project(&self, request: ProjectSelector) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let id = if request.name.is_none() && request.id.is_none() && request.path.is_none() {
                state
                    .active_project_id
                    .clone()
                    .ok_or(BackendError::InactiveProject)?
            } else {
                Self::find_project_id(&state, &request)?
            };
            let project = state
                .projects
                .remove(&id)
                .ok_or_else(|| BackendError::message("project not found"))?;
            if state.active_project_id.as_deref() == Some(id.as_str()) {
                state.active_project_id = None;
            }
            Ok(json!({
                "closed": true,
                "id": project.id,
                "name": project.name,
                "saved": true,
            }))
        })
    }

    fn has_active_project(&self) -> BoxFut<'_, bool> {
        Box::pin(async move { self.state.lock().await.active_project_id.is_some() })
    }

    fn id_universe(&self) -> BoxFut<'_, BackendResult<HashSet<String>>> {
        Box::pin(async move {
            let state = self.state.lock().await;
            let project = Self::active_ref(&state)?;
            Ok(Self::collect_ids(&project.session))
        })
    }

    fn get_timeline(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let state = self.state.lock().await;
            let project = Self::active_ref(&state)?;
            Self::timeline_payload(&project.session, &args)
        })
    }

    fn create_timeline(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            let map = require_object(&args)?;
            reject_unknown_keys(map, &["name", "from"], "create_timeline")?;
            let name = optional_string(map, "name")?;
            let from = optional_string(map, "from")?;
            let mut snapshot = project.session.snapshot();
            let source = if let Some(ref from_id) = from {
                snapshot
                    .project
                    .timelines
                    .iter()
                    .find(|timeline| timeline.id == *from_id)
                    .cloned()
                    .ok_or_else(|| {
                        BackendError::message(format!("No timeline with id '{from_id}'"))
                    })?
            } else {
                let active = snapshot
                    .project
                    .active_timeline_id()
                    .and_then(|id| {
                        snapshot
                            .project
                            .timelines
                            .iter()
                            .find(|timeline| timeline.id == id)
                    })
                    .cloned()
                    .ok_or_else(|| BackendError::message("no active timeline"))?;
                Timeline {
                    id: new_id(),
                    name: name.clone().unwrap_or_else(|| {
                        format!("Timeline {}", snapshot.project.timelines.len() + 1)
                    }),
                    fps: active.fps,
                    width: active.width,
                    height: active.height,
                    settings_configured: active.settings_configured,
                    folder_id: None,
                    tracks: Vec::new(),
                }
            };
            let mut created = source;
            if from.is_some() {
                let mut groups = HashMap::new();
                created.id = new_id();
                for track in &mut created.tracks {
                    track.id = new_id();
                    for clip in &mut track.clips {
                        clip.freshen_ids(&mut groups);
                    }
                }
                created.name = name.unwrap_or_else(|| format!("{} copy", created.name));
            } else if let Some(name) = name {
                created.name = name;
            }
            let note = if from.is_some() {
                "Duplicated and switched to the copy. Its clip and track ids are new."
            } else {
                "Empty and now active; all edit tools target it."
            };
            let created_id = created.id.clone();
            let created_name = created.name.clone();
            snapshot.project.timelines.push(created);
            snapshot.project.active_timeline_id = Some(created_id.clone());
            Self::replace_session(project, snapshot.project, snapshot.media_manifest)?;
            Ok(json!({
                "timelineId": created_id,
                "name": created_name,
                "active": true,
                "note": note,
            }))
        })
    }

    fn set_active_timeline(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            let map = require_object(&args)?;
            reject_unknown_keys(map, &["timelineId"], "set_active_timeline")?;
            let timeline_id = require_string(map, "timelineId")?;
            let mut snapshot = project.session.snapshot();
            let timeline = snapshot
                .project
                .timelines
                .iter()
                .find(|timeline| timeline.id == timeline_id)
                .ok_or_else(|| {
                    BackendError::message(format!("No timeline with id '{timeline_id}'"))
                })?;
            let already =
                snapshot.project.active_timeline_id.as_deref() == Some(timeline_id.as_str());
            let payload = json!({
                "timelineId": timeline.id,
                "name": timeline.name,
                "active": true,
                "totalFrames": timeline.total_frames(),
                "fps": timeline.fps,
                "trackCount": timeline.tracks.len(),
                "note": if already {
                    "Already the active timeline."
                } else {
                    "Re-read get_timeline. Clip and track ids from the previous timeline no longer apply."
                },
            });
            if !already {
                snapshot.project.active_timeline_id = Some(timeline_id);
                Self::replace_session(project, snapshot.project, snapshot.media_manifest)?;
            }
            Ok(payload)
        })
    }

    fn set_project_settings(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            let map = require_object(&args)?;
            reject_unknown_keys(
                map,
                &["fps", "width", "height", "aspectRatio", "quality"],
                "set_project_settings",
            )?;
            let timeline = Self::active_timeline(&project.session)?;
            let fps = optional_i64(map, "fps")?
                .map(|value| value as i32)
                .unwrap_or(timeline.fps);
            let width_arg = optional_i64(map, "width")?.map(|value| value as i32);
            let height_arg = optional_i64(map, "height")?.map(|value| value as i32);
            let aspect = optional_string(map, "aspectRatio")?;
            let quality = optional_string(map, "quality")?;
            let (width, height) =
                match (width_arg, height_arg, aspect.as_deref(), quality.as_deref()) {
                    (Some(width), Some(height), None, None) => (width, height),
                    (None, None, aspect, quality) => {
                        let ratio = if let Some(aspect) = aspect {
                            Self::parse_aspect(Some(aspect))?
                        } else {
                            (timeline.width, timeline.height)
                        };
                        if quality.is_some() || aspect.is_some() {
                            Self::resolve_quality(quality.or(Some("1080p")), ratio)?
                        } else {
                            (timeline.width, timeline.height)
                        }
                    }
                    _ => {
                        return Err(BackendError::message(
                            "width/height can't be combined with aspectRatio or quality",
                        ));
                    }
                };
            if optional_i64(map, "fps")?.is_none()
                && width_arg.is_none()
                && height_arg.is_none()
                && aspect.is_none()
                && quality.is_none()
            {
                return Ok(json!({
                    "status": "noOp",
                    "fps": fps,
                    "width": width,
                    "height": height,
                }));
            }
            let timeline_id = timeline.id.clone();
            let receipt = project
                .session
                .execute(EditorCommand::ChangeProjectSettings {
                    timeline_id,
                    fps,
                    width,
                    height,
                })?;
            let mut payload = Self::receipt_json(&receipt);
            payload["fps"] = json!(fps);
            payload["width"] = json!(width);
            payload["height"] = json!(height);
            Ok(payload)
        })
    }

    fn get_media(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let state = self.state.lock().await;
            let project = Self::active_ref(&state)?;
            let map = require_object(&args)?;
            reject_unknown_keys(map, &["ids", "folder", "pending"], "get_media")?;
            let ids = optional_array(map, "ids")?;
            let pending = optional_bool(map, "pending")?.unwrap_or(false);
            let mut assets: Vec<Value> = project
                .session
                .media_manifest()
                .entries
                .iter()
                .filter(|entry| {
                    if let Some(ids) = ids {
                        ids.iter()
                            .filter_map(Value::as_str)
                            .any(|id| id == entry.id)
                    } else {
                        true
                    }
                })
                .filter(|entry| {
                    if pending {
                        entry.generation_status.is_some()
                    } else {
                        true
                    }
                })
                .map(Self::media_entry_json)
                .collect();
            let mut payload = json!({ "assets": assets });
            if ids.is_none() && !pending {
                payload["timelines"] = json!(
                    project
                        .session
                        .project()
                        .timelines
                        .iter()
                        .map(|timeline| {
                            let mut entry = json!({
                                "timelineId": timeline.id,
                                "name": timeline.name,
                            });
                            if Some(timeline.id.as_str())
                                == project.session.project().active_timeline_id()
                            {
                                entry["active"] = json!(true);
                            }
                            entry
                        })
                        .collect::<Vec<_>>()
                );
                payload["folders"] = json!(
                    project
                        .session
                        .media_manifest()
                        .folders
                        .iter()
                        .map(|folder| folder.name.clone())
                        .collect::<Vec<_>>()
                );
            }
            let _ = &mut assets;
            Ok(payload)
        })
    }

    fn import_media(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            let map = require_object(&args)?;
            reject_unknown_keys(map, &["source", "name", "folder"], "import_media")?;
            let source = map
                .get("source")
                .and_then(Value::as_object)
                .ok_or_else(|| BackendError::message("source is required"))?;
            let name = optional_string(map, "name")?.unwrap_or_else(|| "Imported asset".to_owned());
            let path = optional_string(source, "path")?;
            let url = optional_string(source, "url")?;
            let bytes = optional_string(source, "bytes")?;
            let matte = source.get("matte");
            let set_count = [
                path.is_some(),
                url.is_some(),
                bytes.is_some(),
                matte.is_some(),
            ]
            .into_iter()
            .filter(|value| *value)
            .count();
            if set_count != 1 {
                return Err(BackendError::message(
                    "source must set exactly one of url, path, bytes, or matte",
                ));
            }
            let media_type = if matte.is_some() {
                ClipType::Image
            } else if let Some(path) = &path {
                guess_media_type(path)
            } else if let Some(url) = &url {
                guess_media_type(url)
            } else {
                ClipType::Video
            };
            let id = new_id();
            let entry = MediaManifestEntry {
                id: id.clone(),
                name: name.clone(),
                media_type,
                source: if let Some(path) = path {
                    MediaSource::External {
                        absolute_path: path,
                    }
                } else {
                    MediaSource::Project {
                        relative_path: format!("Media/{id}.bin"),
                    }
                },
                duration: if media_type == ClipType::Image {
                    5.0
                } else {
                    10.0
                },
                generation_input: None,
                source_width: Some(1920),
                source_height: Some(1080),
                source_fps: Some(30.0),
                has_audio: Some(media_type == ClipType::Video || media_type == ClipType::Audio),
                folder_id: None,
                cached_remote_url: url,
                cached_remote_url_expires_at: None,
                generation_status: if bytes.is_some()
                    || matte.is_some()
                    || source.get("path").is_some()
                {
                    None
                } else {
                    Some("downloading".to_owned())
                },
                import_input: None,
            };
            let status = if entry.generation_status.is_some() {
                "downloading"
            } else {
                "ready"
            };
            let mut snapshot = project.session.snapshot();
            snapshot.media_manifest.entries.push(entry);
            Self::replace_session(project, snapshot.project, snapshot.media_manifest)?;
            Ok(json!({
                "mediaRef": id,
                "name": name,
                "status": status,
                "type": media_type,
            }))
        })
    }

    fn organize_media(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            let map = require_object(&args)?;
            let deletes = optional_array(map, "deletes")?.cloned().unwrap_or_default();
            let mut deleted = Vec::new();
            let mut clips_removed = 0_usize;
            let mut snapshot = project.session.snapshot();
            for item in deletes {
                let Some(id) = item.as_str() else {
                    continue;
                };
                if let Some(index) = snapshot
                    .media_manifest
                    .entries
                    .iter()
                    .position(|entry| entry.id == id)
                {
                    snapshot.media_manifest.entries.remove(index);
                    deleted.push(id.to_owned());
                    for timeline in &mut snapshot.project.timelines {
                        for track in &mut timeline.tracks {
                            let before = track.clips.len();
                            track.clips.retain(|clip| clip.media_ref != id);
                            clips_removed += before - track.clips.len();
                        }
                    }
                }
            }
            Self::replace_session(project, snapshot.project, snapshot.media_manifest)?;
            Ok(json!({
                "deleted": deleted,
                "clipsRemoved": clips_removed,
                "createdFolders": [],
                "moved": [],
                "renamed": [],
                "warnings": [],
            }))
        })
    }

    fn capture_frame(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            let map = require_object(&args)?;
            reject_unknown_keys(
                map,
                &["timelineFrame", "mediaRef", "sourceSeconds", "name"],
                "capture_frame",
            )?;
            let timeline_frame = optional_i64(map, "timelineFrame")?;
            let media_ref = optional_string(map, "mediaRef")?;
            let source_seconds = optional_f64(map, "sourceSeconds")?;
            match (timeline_frame, media_ref.as_ref(), source_seconds) {
                (Some(_), None, None) | (None, Some(_), Some(_)) => {}
                _ => {
                    return Err(BackendError::message(
                        "pass timelineFrame alone, or mediaRef with sourceSeconds",
                    ));
                }
            }
            if let Some(media_ref) = &media_ref {
                let _ = Self::resolve_media(&project.session, media_ref)?;
            }
            let id = new_id();
            let name = optional_string(map, "name")?.unwrap_or_else(|| "Captured Frame".to_owned());
            let entry = MediaManifestEntry {
                id: id.clone(),
                name: name.clone(),
                media_type: ClipType::Image,
                source: MediaSource::Project {
                    relative_path: format!("Media/{id}.png"),
                },
                duration: 5.0,
                generation_input: None,
                source_width: Some(
                    Self::active_timeline(&project.session)
                        .map(|timeline| timeline.width)
                        .unwrap_or(1920),
                ),
                source_height: Some(
                    Self::active_timeline(&project.session)
                        .map(|timeline| timeline.height)
                        .unwrap_or(1080),
                ),
                source_fps: None,
                has_audio: Some(false),
                folder_id: None,
                cached_remote_url: None,
                cached_remote_url_expires_at: None,
                generation_status: None,
                import_input: None,
            };
            let mut snapshot = project.session.snapshot();
            snapshot.media_manifest.entries.push(entry);
            Self::replace_session(project, snapshot.project, snapshot.media_manifest)?;
            Ok(json!({
                "mediaRef": id,
                "name": name,
                "type": "image",
                "status": "ready",
            }))
        })
    }

    fn execute(&self, command: EditorCommand) -> BoxFut<'_, BackendResult<MutationReceipt>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            Ok(project.session.execute(command)?)
        })
    }

    fn add_clips(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            let map = require_object(&args)?;
            reject_unknown_keys(map, &["entries"], "add_clips")?;
            let entries = require_array(map, "entries")?;
            if entries.is_empty() {
                return Err(BackendError::message("entries must not be empty"));
            }
            let timeline_id = Self::active_timeline(&project.session)?.id.clone();
            let fps = Self::active_timeline(&project.session)?.fps.max(1);
            let mut created = Vec::new();
            let mut warnings = Vec::new();
            for entry in entries {
                let entry_map = require_object(entry)?;
                reject_unknown_keys(
                    entry_map,
                    &["mediaRef", "trackIndex", "startFrame", "endFrame", "source"],
                    "add_clips.entry",
                )?;
                let media_ref = require_string(entry_map, "mediaRef")?;
                let start_frame = require_i64(entry_map, "startFrame")?;
                let track_index =
                    optional_i64(entry_map, "trackIndex")?.map(|value| value as usize);
                let end_frame = optional_i64(entry_map, "endFrame")?;
                let source = optional_array(entry_map, "source")?;
                let media = Self::resolve_media(&project.session, &media_ref)?.clone();
                let (duration, trim_start, trim_end) =
                    resolve_source_span(&media, fps, start_frame, end_frame, source)?;
                let track_id = Self::ensure_track(
                    &mut project.session,
                    &timeline_id,
                    media.media_type,
                    track_index,
                )?;
                let clip =
                    Self::clip_from_media(&media, start_frame, duration, trim_start, trim_end);
                let receipt = project.session.execute(EditorCommand::AddClips {
                    timeline_id: timeline_id.clone(),
                    track_id,
                    start_frame,
                    clips: vec![clip],
                    mode: AddMode::Overwrite,
                })?;
                created.extend(receipt.created_clip_ids);
                warnings.extend(receipt.warnings);
            }
            Ok(json!({
                "status": if created.is_empty() { "noOp" } else { "applied" },
                "createdClipIds": created,
                "warnings": warnings,
            }))
        })
    }

    fn insert_clips(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            let map = require_object(&args)?;
            reject_unknown_keys(map, &["trackIndex", "atFrame", "entries"], "insert_clips")?;
            let track_index = require_i64(map, "trackIndex")? as usize;
            let at_frame = require_i64(map, "atFrame")?;
            let entries = require_array(map, "entries")?;
            let timeline = Self::active_timeline(&project.session)?;
            let timeline_id = timeline.id.clone();
            let fps = timeline.fps.max(1);
            let track = timeline.tracks.get(track_index).ok_or_else(|| {
                BackendError::message(format!("trackIndex {track_index} is out of range"))
            })?;
            let track_id = track.id.clone();
            let mut cursor = at_frame;
            let mut created = Vec::new();
            for entry in entries {
                let entry_map = require_object(entry)?;
                let media_ref = require_string(entry_map, "mediaRef")?;
                let media = Self::resolve_media(&project.session, &media_ref)?.clone();
                let duration_frames = optional_i64(entry_map, "durationFrames")?;
                let source = optional_array(entry_map, "source")?;
                let (duration, trim_start, trim_end) = if let Some(duration) = duration_frames {
                    (duration, 0, 0)
                } else {
                    resolve_source_span(&media, fps, cursor, None, source)?
                };
                let clip = Self::clip_from_media(&media, cursor, duration, trim_start, trim_end);
                let receipt = project.session.execute(EditorCommand::AddClips {
                    timeline_id: timeline_id.clone(),
                    track_id: track_id.clone(),
                    start_frame: cursor,
                    clips: vec![clip],
                    mode: AddMode::Ripple,
                })?;
                created.extend(receipt.created_clip_ids);
                cursor = cursor.saturating_add(duration);
            }
            Ok(json!({
                "status": "applied",
                "createdClipIds": created,
                "atFrame": at_frame,
            }))
        })
    }

    fn move_clips(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            let map = require_object(&args)?;
            reject_unknown_keys(map, &["moves"], "move_clips")?;
            let moves = require_array(map, "moves")?;
            let timeline = Self::active_timeline(&project.session)?;
            let timeline_id = timeline.id.clone();
            let mut requests = Vec::new();
            for item in moves {
                let item_map = require_object(item)?;
                let clip_id = require_string(item_map, "clipId")?;
                let location = timeline
                    .clip_location(&clip_id)
                    .ok_or_else(|| BackendError::message(format!("clip '{clip_id}' not found")))?;
                let current_track = &timeline.tracks[location.track_index];
                let current_start = current_track.clips[location.clip_index].start_frame;
                let to_track = optional_i64(item_map, "toTrack")?.map(|value| value as usize);
                let to_frame = optional_i64(item_map, "toFrame")?;
                if to_track.is_none() && to_frame.is_none() {
                    return Err(BackendError::message(
                        "each move needs toTrack and/or toFrame",
                    ));
                }
                let track_id = if let Some(index) = to_track {
                    timeline
                        .tracks
                        .get(index)
                        .map(|track| track.id.clone())
                        .ok_or_else(|| {
                            BackendError::message(format!("toTrack {index} is out of range"))
                        })?
                } else {
                    current_track.id.clone()
                };
                let start_frame = to_frame.unwrap_or(current_start);
                requests.push(MoveClipRequest {
                    clip_id,
                    track_id,
                    start_frame,
                });
            }
            let receipt = project.session.execute(EditorCommand::MoveClips {
                timeline_id,
                moves: requests,
            })?;
            Ok(Self::receipt_json(&receipt))
        })
    }

    fn remove_clips(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            let map = require_object(&args)?;
            reject_unknown_keys(map, &["clipIds"], "remove_clips")?;
            let clip_ids = require_array(map, "clipIds")?
                .iter()
                .map(|value| {
                    value
                        .as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| BackendError::message("clipIds must be strings"))
                })
                .collect::<BackendResult<Vec<_>>>()?;
            let timeline_id = Self::active_timeline(&project.session)?.id.clone();
            let receipt = project.session.execute(EditorCommand::RemoveClips {
                timeline_id,
                clip_ids,
                prune_empty_tracks: false,
            })?;
            Ok(Self::receipt_json(&receipt))
        })
    }

    fn split_clips(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            let map = require_object(&args)?;
            let timeline = Self::active_timeline(&project.session)?;
            let timeline_id = timeline.id.clone();
            let mut pairs = Vec::new();
            if let Some(splits) = optional_array(map, "splits")? {
                for split in splits {
                    let split_map = require_object(split)?;
                    pairs.push((
                        require_string(split_map, "clipId")?,
                        require_i64(split_map, "atFrame")?,
                    ));
                }
            } else {
                let track_index = require_i64(map, "trackIndex")? as usize;
                let frames = require_array(map, "frames")?;
                let track = timeline.tracks.get(track_index).ok_or_else(|| {
                    BackendError::message(format!("trackIndex {track_index} is out of range"))
                })?;
                for frame_value in frames {
                    let frame = frame_value
                        .as_i64()
                        .ok_or_else(|| BackendError::message("frames entries must be integers"))?;
                    let clip = track
                        .clips
                        .iter()
                        .find(|clip| clip.contains(frame))
                        .ok_or_else(|| {
                            BackendError::message(format!(
                                "no clip on track {track_index} contains frame {frame}"
                            ))
                        })?;
                    pairs.push((clip.id.clone(), frame));
                }
            }
            if pairs.is_empty() {
                return Err(BackendError::message(
                    "pass splits, or trackIndex with frames",
                ));
            }
            let mut created = Vec::new();
            let mut updated = Vec::new();
            for (clip_id, at_frame) in pairs {
                let receipt = project.session.execute(EditorCommand::SplitClip {
                    timeline_id: timeline_id.clone(),
                    clip_id,
                    at_frame,
                })?;
                created.extend(receipt.created_clip_ids);
                updated.extend(receipt.updated_clip_ids);
            }
            Ok(json!({
                "status": "applied",
                "createdClipIds": created,
                "updatedClipIds": updated,
            }))
        })
    }

    fn ripple_delete_ranges(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            let map = require_object(&args)?;
            let timeline = Self::active_timeline(&project.session)?;
            let timeline_id = timeline.id.clone();
            let ranges_value = require_array(map, "ranges")?;
            let mut ranges = Vec::new();
            for range in ranges_value {
                let values = range
                    .as_array()
                    .ok_or_else(|| BackendError::message("each range must be [start, end]"))?;
                if values.len() != 2 {
                    return Err(BackendError::message("each range must be [start, end]"));
                }
                let start = values[0]
                    .as_i64()
                    .ok_or_else(|| BackendError::message("range values must be integers"))?;
                let end = values[1]
                    .as_i64()
                    .ok_or_else(|| BackendError::message("range values must be integers"))?;
                if end <= start {
                    return Err(BackendError::message(
                        "range end must be greater than start",
                    ));
                }
                ranges.push(FrameRange { start, end });
            }
            let track_id = if let Some(track_index) = optional_i64(map, "trackIndex")? {
                timeline
                    .tracks
                    .get(track_index as usize)
                    .map(|track| track.id.clone())
                    .ok_or_else(|| {
                        BackendError::message(format!("trackIndex {track_index} is out of range"))
                    })?
            } else {
                let clip_id = require_string(map, "clipId")?;
                let location = timeline
                    .clip_location(&clip_id)
                    .ok_or_else(|| BackendError::message(format!("clip '{clip_id}' not found")))?;
                timeline.tracks[location.track_index].id.clone()
            };
            let ignored = optional_array(map, "ignoreSyncLockedTracks")?
                .map(|items| {
                    items
                        .iter()
                        .filter_map(Value::as_i64)
                        .filter_map(|index| {
                            timeline
                                .tracks
                                .get(index as usize)
                                .map(|track| track.id.clone())
                        })
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            let receipt = project.session.execute(EditorCommand::RippleDelete {
                timeline_id,
                track_id,
                ranges,
                ignored_sync_locked_track_ids: ignored,
            })?;
            Ok(Self::receipt_json(&receipt))
        })
    }

    fn manage_clip_links(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            let map = require_object(&args)?;
            let action = require_string(map, "action")?;
            let clip_ids = require_array(map, "clipIds")?
                .iter()
                .map(|value| {
                    value
                        .as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| BackendError::message("clipIds must be strings"))
                })
                .collect::<BackendResult<Vec<_>>>()?;
            let timeline_id = Self::active_timeline(&project.session)?.id.clone();
            let receipt = match action.as_str() {
                "link" => project.session.execute(EditorCommand::LinkClips {
                    timeline_id,
                    clip_ids,
                })?,
                "unlink" => project.session.execute(EditorCommand::UnlinkClips {
                    timeline_id,
                    clip_ids,
                })?,
                other => {
                    return Err(BackendError::message(format!(
                        "unsupported action '{other}'"
                    )));
                }
            };
            Ok(Self::receipt_json(&receipt))
        })
    }

    fn manage_tracks(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            let map = require_object(&args)?;
            let timeline_id = Self::active_timeline(&project.session)?.id.clone();
            let mut receipts = Vec::new();
            if let Some(reorders) = optional_array(map, "reorder")? {
                for item in reorders {
                    let item_map = require_object(item)?;
                    let track_id = if let Some(track_id) = optional_string(item_map, "trackId")? {
                        track_id
                    } else {
                        let index = require_i64(item_map, "index")? as usize;
                        Self::active_timeline(&project.session)?
                            .tracks
                            .get(index)
                            .map(|track| track.id.clone())
                            .ok_or_else(|| {
                                BackendError::message(format!("index {index} is out of range"))
                            })?
                    };
                    let target_index = require_i64(item_map, "to")? as usize;
                    let receipt = project.session.execute(EditorCommand::ReorderTrack {
                        timeline_id: timeline_id.clone(),
                        track_id,
                        target_index,
                    })?;
                    receipts.push(Self::receipt_json(&receipt));
                }
            }
            if let Some(sets) = optional_array(map, "set")? {
                for item in sets {
                    let item_map = require_object(item)?;
                    let track_id = if let Some(track_id) = optional_string(item_map, "trackId")? {
                        track_id
                    } else {
                        let index = require_i64(item_map, "index")? as usize;
                        Self::active_timeline(&project.session)?
                            .tracks
                            .get(index)
                            .map(|track| track.id.clone())
                            .ok_or_else(|| {
                                BackendError::message(format!("index {index} is out of range"))
                            })?
                    };
                    let patch = TrackPatch {
                        muted: optional_bool(item_map, "muted")?,
                        hidden: optional_bool(item_map, "hidden")?,
                        sync_locked: optional_bool(item_map, "syncLocked")?,
                        display_height: None,
                    };
                    let receipt = project.session.execute(EditorCommand::UpdateTrack {
                        timeline_id: timeline_id.clone(),
                        track_id,
                        patch,
                    })?;
                    receipts.push(Self::receipt_json(&receipt));
                }
            }
            if let Some(removes) = optional_array(map, "remove")? {
                let mut track_ids = Vec::new();
                for item in removes {
                    if let Some(index) = item.as_i64() {
                        let track_id = Self::active_timeline(&project.session)?
                            .tracks
                            .get(index as usize)
                            .map(|track| track.id.clone())
                            .ok_or_else(|| {
                                BackendError::message(format!(
                                    "remove index {index} is out of range"
                                ))
                            })?;
                        track_ids.push(track_id);
                    } else {
                        let item_map = require_object(item)?;
                        track_ids.push(require_string(item_map, "trackId")?);
                    }
                }
                if !track_ids.is_empty() {
                    let receipt = project.session.execute(EditorCommand::RemoveTracks {
                        timeline_id: timeline_id.clone(),
                        track_ids,
                    })?;
                    receipts.push(Self::receipt_json(&receipt));
                }
            }
            let order: Vec<Value> = Self::active_timeline(&project.session)?
                .tracks
                .iter()
                .enumerate()
                .map(|(index, track)| {
                    json!({
                        "trackId": track.id,
                        "index": index,
                        "type": track.track_type,
                    })
                })
                .collect();
            Ok(json!({
                "receipts": receipts,
                "tracks": order,
            }))
        })
    }

    fn set_clip_properties(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            let map = require_object(&args)?;
            let clip_ids = require_array(map, "clipIds")?
                .iter()
                .map(|value| {
                    value
                        .as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| BackendError::message("clipIds must be strings"))
                })
                .collect::<BackendResult<Vec<_>>>()?;
            let mut snapshot = project.session.snapshot();
            let mut updated = Vec::new();
            for timeline in &mut snapshot.project.timelines {
                for track in &mut timeline.tracks {
                    for clip in &mut track.clips {
                        if !clip_ids.contains(&clip.id) {
                            continue;
                        }
                        if let Some(duration) = optional_i64(map, "durationFrames")? {
                            clip.set_duration(duration);
                        }
                        if let Some(trim) = optional_i64(map, "trimStartFrame")? {
                            clip.trim_start_frame = trim;
                        }
                        if let Some(trim) = optional_i64(map, "trimEndFrame")? {
                            clip.trim_end_frame = trim;
                        }
                        if let Some(speed) = optional_f64(map, "speed")? {
                            clip.speed = speed;
                        }
                        if let Some(volume_db) = optional_f64(map, "volumeDb")? {
                            clip.volume = db_to_linear(volume_db);
                            clip.volume_track = None;
                        }
                        if let Some(opacity) = optional_f64(map, "opacity")? {
                            clip.opacity = opacity.clamp(0.0, 1.0);
                            clip.opacity_track = None;
                        }
                        if let Some(fade) = optional_i64(map, "fadeInFrames")? {
                            clip.fade_in_frames = fade;
                        }
                        if let Some(fade) = optional_i64(map, "fadeOutFrames")? {
                            clip.fade_out_frames = fade;
                        }
                        if let Some(edge) = optional_f64(map, "edgeRounding")? {
                            clip.edge_rounding = edge.clamp(0.0, 1.0);
                        }
                        if let Some(edge) = optional_f64(map, "edgeSoftness")? {
                            clip.edge_softness = edge.clamp(0.0, 1.0);
                        }
                        if let Some(transform) = map.get("transform") {
                            let patch: BTreeMap<String, Value> =
                                decode_field(transform, "transform")?;
                            if let Some(Value::Number(value)) = patch.get("centerX") {
                                clip.transform.center_x =
                                    value.as_f64().unwrap_or(clip.transform.center_x);
                            }
                            if let Some(Value::Number(value)) = patch.get("centerY") {
                                clip.transform.center_y =
                                    value.as_f64().unwrap_or(clip.transform.center_y);
                            }
                            if let Some(Value::Number(value)) = patch.get("width") {
                                clip.transform.width =
                                    value.as_f64().unwrap_or(clip.transform.width);
                            }
                            if let Some(Value::Number(value)) = patch.get("height") {
                                clip.transform.height =
                                    value.as_f64().unwrap_or(clip.transform.height);
                            }
                            if let Some(Value::Number(value)) = patch.get("rotation") {
                                clip.transform.rotation =
                                    value.as_f64().unwrap_or(clip.transform.rotation);
                                clip.rotation_track = None;
                            }
                        }
                        updated.push(clip.id.clone());
                    }
                }
            }
            if updated.is_empty() {
                return Ok(json!({ "status": "noOp", "updatedClipIds": [] }));
            }
            Self::replace_session(project, snapshot.project, snapshot.media_manifest)?;
            Ok(json!({
                "status": "applied",
                "updatedClipIds": updated,
            }))
        })
    }

    fn add_texts(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            let map = require_object(&args)?;
            let entries = require_array(map, "entries")?;
            let timeline_id = Self::active_timeline(&project.session)?.id.clone();
            let track_id =
                Self::ensure_track(&mut project.session, &timeline_id, ClipType::Text, None)?;
            let mut created = Vec::new();
            for entry in entries {
                let entry_map = require_object(entry)?;
                let content = require_string(entry_map, "content")?;
                let start_frame = require_i64(entry_map, "startFrame")?;
                let end_frame = optional_i64(entry_map, "endFrame")?.unwrap_or(start_frame + 90);
                if end_frame <= start_frame {
                    return Err(BackendError::message(
                        "endFrame must be greater than startFrame",
                    ));
                }
                let mut clip = Clip::new(new_id(), start_frame, end_frame - start_frame);
                clip.media_ref = String::new();
                clip.media_type = ClipType::Text;
                clip.source_clip_type = ClipType::Text;
                clip.text_content = Some(content);
                clip.text_style = Some(TextStyle::default());
                let receipt = project.session.execute(EditorCommand::AddClips {
                    timeline_id: timeline_id.clone(),
                    track_id: track_id.clone(),
                    start_frame,
                    clips: vec![clip],
                    mode: AddMode::Overwrite,
                })?;
                created.extend(receipt.created_clip_ids);
            }
            Ok(json!({
                "status": "applied",
                "createdClipIds": created,
            }))
        })
    }

    fn update_text(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            let map = require_object(&args)?;
            let clip_ids = optional_array(map, "clipIds")?
                .map(|items| {
                    items
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            let caption_group_id = optional_string(map, "captionGroupId")?;
            if clip_ids.is_empty() && caption_group_id.is_none() {
                return Err(BackendError::message(
                    "clipIds or captionGroupId is required",
                ));
            }
            let content = optional_string(map, "content")?;
            let mut snapshot = project.session.snapshot();
            let mut updated = Vec::new();
            for timeline in &mut snapshot.project.timelines {
                for track in &mut timeline.tracks {
                    for clip in &mut track.clips {
                        let matches = clip_ids.contains(&clip.id)
                            || caption_group_id
                                .as_ref()
                                .is_some_and(|group| clip.caption_group_id.as_ref() == Some(group));
                        if !matches || clip.media_type != ClipType::Text {
                            continue;
                        }
                        if let Some(content) = &content {
                            clip.text_content = Some(content.clone());
                        }
                        updated.push(clip.id.clone());
                    }
                }
            }
            if updated.is_empty() {
                return Ok(json!({ "status": "noOp", "updatedClipIds": [] }));
            }
            Self::replace_session(project, snapshot.project, snapshot.media_manifest)?;
            Ok(json!({
                "status": "applied",
                "updatedClipIds": updated,
            }))
        })
    }

    fn apply_color(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            let map = require_object(&args)?;
            let clip_ids = require_array(map, "clipIds")?
                .iter()
                .map(|value| {
                    value
                        .as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| BackendError::message("clipIds must be strings"))
                })
                .collect::<BackendResult<Vec<_>>>()?;
            let reset = optional_bool(map, "reset")?.unwrap_or(false);
            let mut snapshot = project.session.snapshot();
            let mut updated = Vec::new();
            for timeline in &mut snapshot.project.timelines {
                for track in &mut timeline.tracks {
                    for clip in &mut track.clips {
                        if !clip_ids.contains(&clip.id) {
                            continue;
                        }
                        let mut effects = if reset {
                            Vec::new()
                        } else {
                            clip.effects.clone().unwrap_or_default()
                        };
                        effects.retain(|effect| !effect.effect_type.starts_with("color."));
                        let mut color = Effect::new("color.grade");
                        for key in [
                            "exposure",
                            "contrast",
                            "saturation",
                            "temperature",
                            "tint",
                            "highlights",
                            "shadows",
                        ] {
                            if let Some(value) = optional_f64(map, key)? {
                                color.params.insert(
                                    key.to_owned(),
                                    EffectParam {
                                        value: Some(value),
                                        string: None,
                                        track: None,
                                    },
                                );
                            }
                        }
                        if let Some(color_object) = map.get("color").and_then(Value::as_object) {
                            for (key, value) in color_object {
                                if let Some(number) = value.as_f64() {
                                    color.params.insert(
                                        key.clone(),
                                        EffectParam {
                                            value: Some(number),
                                            string: None,
                                            track: None,
                                        },
                                    );
                                }
                            }
                        }
                        if !color.params.is_empty() || reset || map.get("color").is_some() {
                            effects.push(color);
                        }
                        clip.effects = if effects.is_empty() {
                            None
                        } else {
                            Some(effects)
                        };
                        updated.push(json!({
                            "clipId": clip.id,
                            "color": clip.effects.as_ref().and_then(|effects| {
                                effects.iter().find(|effect| effect.effect_type.starts_with("color.")).map(|effect| {
                                    let params: BTreeMap<&str, f64> = effect
                                        .params
                                        .iter()
                                        .filter_map(|(key, param)| {
                                            param.value.map(|value| (key.as_str(), value))
                                        })
                                        .collect();
                                    json!({ "type": effect.effect_type, "params": params })
                                })
                            }),
                        }));
                    }
                }
            }
            if updated.is_empty() {
                return Ok(json!({ "status": "noOp", "clips": [] }));
            }
            Self::replace_session(project, snapshot.project, snapshot.media_manifest)?;
            Ok(json!({ "status": "applied", "clips": updated }))
        })
    }

    fn apply_effect(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            let map = require_object(&args)?;
            let clip_ids = require_array(map, "clipIds")?
                .iter()
                .map(|value| {
                    value
                        .as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| BackendError::message("clipIds must be strings"))
                })
                .collect::<BackendResult<Vec<_>>>()?;
            let effects_arg = optional_array(map, "effects")?.cloned().unwrap_or_default();
            let remove = optional_array(map, "remove")?
                .map(|items| {
                    items
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect::<HashSet<_>>()
                })
                .unwrap_or_default();
            let mut snapshot = project.session.snapshot();
            let mut updated = Vec::new();
            for timeline in &mut snapshot.project.timelines {
                for track in &mut timeline.tracks {
                    for clip in &mut track.clips {
                        if !clip_ids.contains(&clip.id) {
                            continue;
                        }
                        let mut effects = clip.effects.clone().unwrap_or_default();
                        effects.retain(|effect| !remove.contains(&effect.effect_type));
                        for effect_value in &effects_arg {
                            let effect_map = require_object(effect_value)?;
                            let effect_type = require_string(effect_map, "type")?;
                            if effect_type.starts_with("color.") {
                                return Err(BackendError::message(
                                    "use apply_color for color.* effects",
                                ));
                            }
                            let enabled = optional_bool(effect_map, "enabled")?.unwrap_or(true);
                            let params = effect_map
                                .get("params")
                                .and_then(Value::as_object)
                                .cloned()
                                .unwrap_or_default();
                            let parsed_params: BTreeMap<String, EffectParam> = params
                                .into_iter()
                                .filter_map(|(key, value)| {
                                    value.as_f64().map(|number| {
                                        (
                                            key,
                                            EffectParam {
                                                value: Some(number),
                                                string: None,
                                                track: None,
                                            },
                                        )
                                    })
                                })
                                .collect();
                            if let Some(existing) = effects
                                .iter_mut()
                                .find(|effect| effect.effect_type == effect_type)
                            {
                                existing.enabled = enabled;
                                for (key, value) in parsed_params {
                                    existing.params.insert(key, value);
                                }
                            } else {
                                let mut effect = Effect::new(effect_type);
                                effect.enabled = enabled;
                                effect.params = parsed_params;
                                effects.push(effect);
                            }
                        }
                        clip.effects = if effects.is_empty() {
                            None
                        } else {
                            Some(effects)
                        };
                        updated.push(json!({
                            "clipId": clip.id,
                            "effects": clip.effects.as_ref().map(|effects| {
                                effects.iter().map(|effect| {
                                    let params: BTreeMap<&str, f64> = effect
                                        .params
                                        .iter()
                                        .filter_map(|(key, param)| {
                                            param.value.map(|value| (key.as_str(), value))
                                        })
                                        .collect();
                                    json!({
                                        "type": effect.effect_type,
                                        "params": params,
                                        "enabled": effect.enabled,
                                    })
                                }).collect::<Vec<_>>()
                            }).unwrap_or_default(),
                        }));
                    }
                }
            }
            if updated.is_empty() {
                return Ok(json!({ "status": "noOp", "clips": [] }));
            }
            Self::replace_session(project, snapshot.project, snapshot.media_manifest)?;
            Ok(json!({ "status": "applied", "clips": updated }))
        })
    }

    fn export_project(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_ref(&state)?;
            let map = require_object(&args)?;
            let mode = optional_string(map, "mode")?.unwrap_or_else(|| "video".to_owned());
            let filename = format!(
                "{}.{}",
                project.name.replace(' ', "_"),
                export_extension(&mode)
            );
            let path =
                optional_string(map, "outputPath")?.unwrap_or_else(|| format!("/tmp/{filename}"));
            let job_id = new_id();
            state.exports.push(ExportJob {
                job_id: job_id.clone(),
                filename: filename.clone(),
                path: path.clone(),
                status: "started".to_owned(),
                progress: 0.0,
                mode: mode.clone(),
            });
            Ok(json!({
                "status": "started",
                "jobId": job_id,
                "path": path,
                "filename": filename,
                "mode": mode,
            }))
        })
    }

    fn manage_exports(&self, args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let map = require_object(&args)?;
            let action = require_string(map, "action")?;
            match action.as_str() {
                "list" => {
                    let jobs: Vec<Value> = state
                        .exports
                        .iter()
                        .rev()
                        .map(|job| {
                            json!({
                                "jobId": job.job_id,
                                "filename": job.filename,
                                "path": job.path,
                                "status": job.status,
                                "progress": job.progress,
                                "mode": job.mode,
                            })
                        })
                        .collect();
                    Ok(json!({ "exports": jobs }))
                }
                "cancel" => {
                    let job_id = require_string(map, "jobId")?;
                    if let Some(job) = state.exports.iter_mut().find(|job| job.job_id == job_id) {
                        job.status = "canceled".to_owned();
                        Ok(json!({ "jobId": job_id, "status": "canceled" }))
                    } else {
                        Err(BackendError::message(format!(
                            "export job '{job_id}' not found"
                        )))
                    }
                }
                other => Err(BackendError::message(format!(
                    "unsupported action '{other}'"
                ))),
            }
        })
    }

    fn undo(&self, _args: Value) -> BoxFut<'_, BackendResult<Value>> {
        Box::pin(async move {
            let mut state = self.state.lock().await;
            let project = Self::active_mut(&mut state)?;
            let receipt = project.session.execute(EditorCommand::Undo)?;
            let status = match receipt.status {
                MutationStatus::Undone => "undone",
                MutationStatus::NoOp => "noOp",
                _ => "applied",
            };
            let mut payload = Self::receipt_json(&receipt);
            payload["status"] = json!(status);
            Ok(payload)
        })
    }
}

fn guess_media_type(path: &str) -> ClipType {
    let lowered = path.to_ascii_lowercase();
    if lowered.ends_with(".png")
        || lowered.ends_with(".jpg")
        || lowered.ends_with(".jpeg")
        || lowered.ends_with(".tiff")
        || lowered.ends_with(".heic")
    {
        ClipType::Image
    } else if lowered.ends_with(".mp3")
        || lowered.ends_with(".wav")
        || lowered.ends_with(".aac")
        || lowered.ends_with(".m4a")
        || lowered.ends_with(".flac")
    {
        ClipType::Audio
    } else {
        ClipType::Video
    }
}

fn resolve_source_span(
    media: &MediaManifestEntry,
    fps: i32,
    start_frame: i64,
    end_frame: Option<i64>,
    source: Option<&Vec<Value>>,
) -> BackendResult<(i64, i64, i64)> {
    if let Some(end_frame) = end_frame {
        if end_frame <= start_frame {
            return Err(BackendError::message(
                "endFrame must be greater than startFrame",
            ));
        }
        return Ok((end_frame - start_frame, 0, 0));
    }
    if let Some(source) = source {
        if source.len() != 2 {
            return Err(BackendError::message(
                "source must be [startSeconds, endSeconds]",
            ));
        }
        let start = source[0]
            .as_f64()
            .ok_or_else(|| BackendError::message("source values must be numbers"))?;
        let end = source[1]
            .as_f64()
            .ok_or_else(|| BackendError::message("source values must be numbers"))?;
        if end <= start {
            return Err(BackendError::message(
                "source endSeconds must be greater than startSeconds",
            ));
        }
        let trim_start = (start * f64::from(fps)).round() as i64;
        let duration = ((end - start) * f64::from(fps)).round() as i64;
        return Ok((duration.max(1), trim_start, 0));
    }
    let duration = (media.duration * f64::from(fps)).round() as i64;
    Ok((duration.max(1), 0, 0))
}

fn db_to_linear(db: f64) -> f64 {
    if db <= -60.0 {
        0.0
    } else {
        10_f64.powf(db / 20.0)
    }
}

fn export_extension(mode: &str) -> &'static str {
    match mode {
        "xml" => "xml",
        "fcpxml" => "fcpxml",
        "palmier" => "palmier",
        _ => "mp4",
    }
}
