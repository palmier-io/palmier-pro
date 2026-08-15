use chrono::{TimeZone, Utc};
use palmier_core::{ClipType, MediaSource};
use palmier_project::ProjectEntry;
use palmier_service::ProjectView;

use crate::dto::{
    ClipTransform, MediaAsset, MediaStatus, ProjectDocument, RecentProject, TimelineClip,
    TimelineTrack, UiEditResult, UiPreviewEditResult,
};

const ACCENTS: [&str; 6] = ["moss", "amber", "violet", "slate", "rose", "ocean"];

pub fn swift_date_to_iso(seconds: f64) -> String {
    let unix = seconds + palmier_core::SwiftDate::APPLE_REFERENCE_UNIX_SECONDS;
    let secs = unix.trunc() as i64;
    let nanos = ((unix.fract() * 1_000_000_000.0).round() as u32).min(999_999_999);
    Utc.timestamp_opt(secs, nanos)
        .single()
        .unwrap_or_else(Utc::now)
        .to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

pub fn recent_project(entry: &ProjectEntry) -> RecentProject {
    RecentProject {
        id: entry.id.to_string(),
        name: entry.name(),
        path: entry.url.display().to_string(),
        updated_at: swift_date_to_iso(entry.last_opened_date.0),
        duration_label: String::new(),
    }
}

pub fn project_document(view: &ProjectView) -> ProjectDocument {
    let path = view
        .summary
        .path
        .as_ref()
        .map(|path| path.display().to_string());
    let name = path
        .as_ref()
        .and_then(|value| {
            std::path::Path::new(value)
                .file_stem()
                .map(|stem| stem.to_string_lossy().into_owned())
        })
        .or_else(|| {
            view.snapshot
                .project
                .timelines
                .first()
                .map(|timeline| timeline.name.clone())
        })
        .unwrap_or_else(|| "Untitled".into());

    let timeline = view
        .snapshot
        .project
        .active_timeline_id()
        .and_then(|id| {
            view.snapshot
                .project
                .timelines
                .iter()
                .find(|timeline| timeline.id == id)
        })
        .or_else(|| view.snapshot.project.timelines.first());

    let (timeline_id, width, height, fps, tracks) = match timeline {
        Some(timeline) => (
            timeline.id.clone(),
            timeline.width,
            timeline.height,
            timeline.fps,
            map_tracks(timeline, &view.snapshot.media_manifest.entries),
        ),
        None => (String::new(), 1920, 1080, 30, Vec::new()),
    };

    let media = view
        .snapshot
        .media_manifest
        .entries
        .iter()
        .map(|entry| map_media_entry(entry, fps))
        .collect();

    ProjectDocument {
        id: view.summary.project_id.to_string(),
        name,
        path,
        timeline_id,
        width,
        height,
        fps,
        updated_at: Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        media,
        tracks,
    }
}

pub fn ui_edit_result(view: &ProjectView, receipt: palmier_core::MutationReceipt) -> UiEditResult {
    UiEditResult {
        receipt,
        project: project_document(view),
        revision: view.summary.revision,
        dirty: view.summary.dirty,
        undo_depth: view.summary.undo_depth,
        redo_depth: view.summary.redo_depth,
    }
}

pub fn ui_preview_edit_result(
    view: &ProjectView,
    receipt: palmier_core::MutationReceipt,
    expected_revision: u64,
) -> UiPreviewEditResult {
    UiPreviewEditResult {
        receipt,
        project: project_document(view),
        expected_revision,
    }
}

fn map_tracks(
    timeline: &palmier_core::Timeline,
    media: &[palmier_core::MediaManifestEntry],
) -> Vec<TimelineTrack> {
    let mut video_index = 0usize;
    let mut audio_index = 0usize;
    timeline
        .tracks
        .iter()
        .map(|track| {
            let kind = match track.track_type {
                ClipType::Audio => {
                    audio_index += 1;
                    "audio"
                }
                ClipType::Video
                | ClipType::Image
                | ClipType::Text
                | ClipType::Lottie
                | ClipType::Sequence => {
                    video_index += 1;
                    "video"
                }
            };
            let name = if kind == "audio" {
                format!("A{audio_index}")
            } else {
                format!("V{video_index}")
            };
            TimelineTrack {
                id: track.id.clone(),
                name,
                kind: kind.into(),
                muted: track.muted,
                hidden: track.hidden,
                locked: false,
                clips: track
                    .clips
                    .iter()
                    .map(|clip| map_clip(clip, &track.id, media))
                    .collect(),
            }
        })
        .collect()
}

fn map_clip(
    clip: &palmier_core::Clip,
    track_id: &str,
    media: &[palmier_core::MediaManifestEntry],
) -> TimelineClip {
    let entry = media.iter().find(|entry| entry.id == clip.media_ref);
    let kind = media_kind(clip.media_type);
    let name = entry
        .map(|entry| entry.name.clone())
        .filter(|value| !value.is_empty())
        .or_else(|| clip.text_content.clone().filter(|value| !value.is_empty()))
        .unwrap_or_else(|| clip.media_ref.clone());
    TimelineClip {
        id: clip.id.clone(),
        asset_id: clip.media_ref.clone(),
        name,
        kind,
        track_id: track_id.to_owned(),
        start_frame: clip.start_frame,
        duration_frames: clip.duration_frames,
        source_offset_frames: clip.trim_start_frame,
        trim_end_frames: clip.trim_end_frame,
        speed: clip.speed,
        volume: clip.volume,
        fade_in_frames: clip.fade_in_frames,
        fade_out_frames: clip.fade_out_frames,
        link_group_id: clip.link_group_id.clone(),
        transform: ClipTransform {
            position_x: (clip.transform.center_x - 0.5) * 100.0,
            position_y: (clip.transform.center_y - 0.5) * 100.0,
            scale: clip.transform.width * 100.0,
            rotation: clip.transform.rotation,
            opacity: clip.opacity * 100.0,
        },
    }
}

fn map_media_entry(entry: &palmier_core::MediaManifestEntry, fps: i32) -> MediaAsset {
    let fps = if fps > 0 { f64::from(fps) } else { 30.0 };
    let duration_frames = if entry.duration.is_finite() && entry.duration > 0.0 {
        (entry.duration * fps).round() as i64
    } else {
        0
    };
    let source_path = match &entry.source {
        MediaSource::External { absolute_path } => Some(absolute_path.clone()),
        MediaSource::Project { relative_path } => Some(relative_path.clone()),
    };
    let accent = ACCENTS[accent_index(&entry.id)].to_owned();
    let generated = entry.generation_input.is_some();
    let status = match entry.generation_status.as_deref() {
        Some("failed") => MediaStatus {
            kind: "failed".into(),
            progress: None,
            label: None,
            reason: None,
            message: Some("generation failed".into()),
        },
        Some(label) if label != "ready" && label != "completed" => {
            MediaStatus::generating(0.0, label.to_owned())
        }
        _ => MediaStatus::ready(),
    };
    MediaAsset {
        id: entry.id.clone(),
        name: entry.name.clone(),
        kind: media_kind(entry.media_type),
        duration_frames,
        width: entry.source_width,
        height: entry.source_height,
        source_path,
        created_at: Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        status,
        accent,
        generated: generated.then_some(true),
        has_audio: entry.has_audio.unwrap_or(false),
    }
}

fn media_kind(value: ClipType) -> String {
    match value {
        ClipType::Audio => "audio".into(),
        ClipType::Image => "image".into(),
        ClipType::Video | ClipType::Text | ClipType::Lottie | ClipType::Sequence => "video".into(),
    }
}

fn accent_index(id: &str) -> usize {
    let hash = id.bytes().fold(0usize, |acc, byte| {
        acc.wrapping_mul(31).wrapping_add(usize::from(byte))
    });
    hash % ACCENTS.len()
}

pub fn safe_project_filename(name: &str) -> String {
    let trimmed = name.trim();
    let mut out = String::with_capacity(trimmed.len());
    for ch in trimmed.chars() {
        if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
            out.push(ch);
        } else if ch.is_whitespace() {
            if !out.ends_with('-') {
                out.push('-');
            }
        }
    }
    let cleaned = out.trim_matches('-');
    if cleaned.is_empty() {
        "Untitled".into()
    } else {
        cleaned.to_owned()
    }
}
