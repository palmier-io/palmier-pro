use std::path::{Path, PathBuf};
use std::sync::Arc;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use chrono::Utc;
use palmier_core::{AddMode, Clip, ClipType, EditorCommand};
use palmier_generation::{FAL_API_KEY, GenerationRequest, JobState, REPLICATE_API_TOKEN};
use palmier_media::{
    AudioExportSettings, DecodedFrameData, ExportFrameSource, ExportRequest as MediaExportRequest,
    ExportSettings, ExportState, FrameOutput, PausedFrameRequest, PreparedProjectRender,
    decode_pcm_range, discover_codec_capabilities, encode_jpeg, prepare_project_render,
    resolve_media_path,
};
use palmier_project::{PROJECT_FILE_EXTENSION, ProjectSnapshot, is_project_package_path};
use palmier_service::{ImportMode, ProjectView};
use serde_json::Value;
use tauri::{AppHandle, State};
use tauri_plugin_dialog::DialogExt;
use uuid::Uuid;

use crate::dto::{
    DecodePreviewFrameResult, ImportCandidate, MediaAsset, MediaStatus, PreviewAudio,
    ProjectDocument, ProviderSettings, StartGenerationResult, UiBootstrapPayload, UiEditResult,
    UiExportJob, UiExportRequest, UiGenerationJob, UiGenerationRequest, UiPreviewEditResult,
};
use crate::error::{AppError, AppResult};
use crate::map::{
    project_document, recent_project, safe_project_filename, ui_edit_result, ui_preview_edit_result,
};
use crate::state::{AppState, RenderCacheEntry};

#[tauri::command]
pub async fn editor_bootstrap(state: State<'_, Arc<AppState>>) -> AppResult<UiBootstrapPayload> {
    let bootstrap = state.editor.bootstrap().await?;
    let recent_projects = bootstrap
        .recent_projects
        .iter()
        .map(recent_project)
        .collect();
    let settings = load_provider_settings(&state).await?;
    Ok(UiBootstrapPayload {
        recent_projects,
        settings,
    })
}

#[tauri::command]
pub async fn create_project(
    state: State<'_, Arc<AppState>>,
    name: String,
) -> AppResult<ProjectDocument> {
    let view = state.editor.create_project().await?;
    let projects_dir = default_projects_dir();
    tokio::fs::create_dir_all(&projects_dir)
        .await
        .map_err(|error| AppError::message(format!("create projects directory: {error}")))?;
    let filename = format!(
        "{}.{}",
        safe_project_filename(&name),
        PROJECT_FILE_EXTENSION
    );
    let destination = unique_destination(projects_dir.join(filename)).await?;
    let _ = state
        .editor
        .save_project_as(view.summary.project_id, &destination)
        .await?;
    let view = state.editor.project_view(view.summary.project_id).await?;
    let mut document = project_document(&view);
    document.name = name;
    Ok(document)
}

#[tauri::command]
pub async fn open_project(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    path: Option<String>,
) -> AppResult<ProjectDocument> {
    let path = match path {
        Some(path) if !path.trim().is_empty() => PathBuf::from(path),
        _ => pick_project_path(&app)?,
    };
    let view = state.editor.open_project(path).await?;
    Ok(project_document(&view))
}

#[tauri::command]
pub async fn import_media(
    state: State<'_, Arc<AppState>>,
    project_id: String,
    files: Vec<ImportCandidate>,
) -> AppResult<Vec<MediaAsset>> {
    let project_id = parse_uuid(&project_id, "projectId")?;
    let paths = files
        .into_iter()
        .filter_map(|file| file.path.map(PathBuf::from))
        .filter(|path| !path.as_os_str().is_empty())
        .collect::<Vec<_>>();
    if paths.is_empty() {
        return Err(AppError::message(
            "import_media requires absolute file paths from the native dialog",
        ));
    }
    import_media_paths(&state, project_id, paths).await
}

#[tauri::command]
pub async fn import_media_dialog(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    project_id: String,
) -> AppResult<Vec<MediaAsset>> {
    let project_id = parse_uuid(&project_id, "projectId")?;
    let paths = pick_import_paths(&app)?;
    if paths.is_empty() {
        return Err(AppError::message("import canceled"));
    }
    import_media_paths(&state, project_id, paths).await
}

async fn import_media_paths(
    state: &AppState,
    project_id: Uuid,
    paths: Vec<PathBuf>,
) -> AppResult<Vec<MediaAsset>> {
    let mode = if state
        .editor
        .project_view(project_id)
        .await?
        .summary
        .path
        .is_some()
    {
        ImportMode::InstallIntoPackage
    } else {
        ImportMode::ExternalRefs
    };
    let result = state
        .editor
        .import_local_files(project_id, paths, mode, None)
        .await?;
    let view = state.editor.project_view(project_id).await?;
    let document = project_document(&view);
    let imported_ids = result
        .entries
        .iter()
        .map(|entry| entry.asset_id.as_str())
        .collect::<Vec<_>>();
    Ok(document
        .media
        .into_iter()
        .filter(|asset| imported_ids.contains(&asset.id.as_str()))
        .collect())
}

#[tauri::command]
pub async fn persist_project(
    state: State<'_, Arc<AppState>>,
    project: ProjectDocument,
) -> AppResult<()> {
    let project_id = parse_uuid(&project.id, "project.id")?;
    let view = state.editor.project_view(project_id).await?;
    if view.summary.path.is_none() {
        let destination = match project.path.as_deref() {
            Some(path) if !path.is_empty() => PathBuf::from(path),
            _ => {
                let projects_dir = default_projects_dir();
                tokio::fs::create_dir_all(&projects_dir)
                    .await
                    .map_err(|error| {
                        AppError::message(format!("create projects directory: {error}"))
                    })?;
                unique_destination(projects_dir.join(format!(
                    "{}.{}",
                    safe_project_filename(&project.name),
                    PROJECT_FILE_EXTENSION
                )))
                .await?
            }
        };
        let _ = state
            .editor
            .save_project_as(project_id, destination)
            .await?;
        return Ok(());
    }
    let _ = state.editor.save_project(project_id).await?;
    Ok(())
}

#[tauri::command]
pub async fn save_provider_settings(
    state: State<'_, Arc<AppState>>,
    settings: ProviderSettings,
) -> AppResult<()> {
    let credentials = state.generation.credentials();
    set_or_clear_secret(credentials, FAL_API_KEY, &settings.fal_key)?;
    set_or_clear_secret(credentials, REPLICATE_API_TOKEN, &settings.replicate_key)?;
    Ok(())
}

#[tauri::command]
pub async fn start_generation(
    state: State<'_, Arc<AppState>>,
    request: UiGenerationRequest,
) -> AppResult<StartGenerationResult> {
    let project_id = parse_uuid(&request.project_id, "projectId")?;
    let _ = state.editor.project_view(project_id).await?;
    let generation_request = GenerationRequest {
        model_id: request.model.clone(),
        prompt: request.prompt.clone(),
        aspect_ratio: Some(request.aspect_ratio.clone()),
        duration: Some(request.duration_seconds),
        resolution: None,
        quality: None,
        reference_urls: Vec::new(),
        reference_paths: Vec::new(),
        source_url: None,
        num_outputs: None,
        stage_dir: Some(state.stage_dir.clone()),
    };
    let job = state.generation.start(generation_request).await?;
    let asset_id = format!("asset-{}", job.id);
    let label = format!("Generating with {}", request.model);
    let ui_job = UiGenerationJob {
        id: job.id.clone(),
        asset_id: asset_id.clone(),
        label: label.clone(),
        progress: 0.0,
        status: map_job_status(&job.state),
        error: job.error.clone(),
    };
    let duration_frames = if request.kind == "image" {
        120
    } else {
        i64::from(request.duration_seconds) * 30
    };
    let asset = MediaAsset {
        id: asset_id.clone(),
        name: format!("{}_{}", request.kind, &job.id[..8.min(job.id.len())]),
        kind: request.kind.clone(),
        duration_frames,
        width: if request.kind == "audio" {
            None
        } else {
            Some(1920)
        },
        height: if request.kind == "audio" {
            None
        } else {
            Some(1080)
        },
        source_path: None,
        created_at: Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        status: MediaStatus::generating(0.0, label),
        accent: "violet".into(),
        generated: Some(true),
        has_audio: request.kind != "image",
    };
    state
        .generation_assets
        .lock()
        .await
        .insert(job.id.clone(), asset_id);
    state
        .generation_projects
        .lock()
        .await
        .insert(job.id.clone(), project_id);
    Ok(StartGenerationResult { job: ui_job, asset })
}

#[tauri::command]
pub async fn list_generation_jobs(
    state: State<'_, Arc<AppState>>,
    project_id: String,
) -> AppResult<Vec<UiGenerationJob>> {
    let project_id = parse_uuid(&project_id, "projectId")?;
    let projects = state.generation_projects.lock().await.clone();
    let assets = state.generation_assets.lock().await.clone();
    let mut jobs = Vec::new();
    for job in state.generation.list_jobs().await {
        if projects.get(&job.id) != Some(&project_id) {
            continue;
        }
        let asset_id = assets
            .get(&job.id)
            .cloned()
            .unwrap_or_else(|| format!("asset-{}", job.id));
        let progress = match job.state {
            JobState::Preparing => 0.05,
            JobState::Running => 0.45,
            JobState::Downloading => 0.8,
            JobState::Ready => 1.0,
            JobState::Failed | JobState::Cancelled => 1.0,
        };
        jobs.push(UiGenerationJob {
            id: job.id.clone(),
            asset_id,
            label: format!("Generating with {}", job.model_id),
            progress,
            status: map_job_status(&job.state),
            error: job.error.clone(),
        });
    }
    Ok(jobs)
}

#[tauri::command]
pub async fn start_export(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    request: UiExportRequest,
) -> AppResult<UiExportJob> {
    let project_id = parse_uuid(&request.project_id, "projectId")?;
    let view = state.editor.project_view(project_id).await?;
    let extension = export_extension(&request);
    let stem = view
        .summary
        .path
        .as_ref()
        .and_then(|path| {
            path.file_stem()
                .map(|stem| stem.to_string_lossy().into_owned())
        })
        .unwrap_or_else(|| "export".into());
    let filename = format!("{stem}.{extension}");
    let destination = pick_export_path(&app, &filename, extension)?;
    if request.destination == "project" {
        let source = view
            .summary
            .path
            .as_ref()
            .ok_or_else(|| AppError::message("save the project before exporting a package"))?;
        state
            .editor
            .store()
            .save_as(
                source,
                &destination,
                ProjectSnapshot::new(
                    view.snapshot.project.clone(),
                    view.snapshot.media_manifest.clone(),
                ),
            )
            .await?;
        return completed_export_job(project_id, filename);
    }
    if request.destination == "timeline" {
        let timeline = active_timeline(&view)?;
        let xml = if request.timeline_format.eq_ignore_ascii_case("XMEML") {
            xmeml_document(timeline)
        } else {
            fcpxml_document(timeline)
        };
        write_atomic(&destination, xml.as_bytes()).await?;
        return completed_export_job(project_id, filename);
    }

    let output_size = export_size(&view, &request.resolution)?;
    let render = prepared_render(&state, &view, output_size).await?;
    let encoder = video_encoder_name(&request.codec).await?;
    let media_request = MediaExportRequest {
        destination,
        overwrite: true,
        plan: render.plan.clone(),
        media: render.media.clone(),
        settings: ExportSettings {
            video_bit_rate: 12_000_000,
            video_encoder: Some(encoder),
            audio: render.has_audio.then_some(AudioExportSettings {
                sample_rate: 48_000,
                channels: 2,
                bit_rate: 192_000,
            }),
        },
    };
    let source: Arc<dyn ExportFrameSource> = render.source.clone();
    let id = state
        .editor
        .start_export(project_id, media_request, source)
        .await?
        .as_uuid()
        .to_string();
    let job = UiExportJob {
        id: id.clone(),
        filename,
        progress: 0.0,
        status: "waiting".into(),
        created_at: Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        error: None,
        project_id: Some(project_id.to_string()),
    };
    state
        .export_jobs
        .lock()
        .await
        .insert(id.clone(), job.clone());
    Ok(job)
}

#[tauri::command]
pub async fn list_export_jobs(
    state: State<'_, Arc<AppState>>,
    project_id: String,
) -> AppResult<Vec<UiExportJob>> {
    let project_id = parse_uuid(&project_id, "projectId")?;
    let summaries = state.editor.list_exports().await;
    let mut jobs = state.export_jobs.lock().await;
    for summary in summaries
        .into_iter()
        .filter(|summary| summary.project_id == project_id)
    {
        if let Some(job) = jobs.get_mut(&summary.job_id.to_string()) {
            apply_export_state(job, &summary.state);
        }
    }
    let project_id = project_id.to_string();
    Ok(jobs
        .values()
        .filter(|job| job.project_id.as_deref() == Some(project_id.as_str()))
        .cloned()
        .collect())
}

#[tauri::command]
pub async fn cancel_export(state: State<'_, Arc<AppState>>, job_id: String) -> AppResult<()> {
    let uuid = parse_uuid(&job_id, "jobId")?;
    state.editor.cancel_export(uuid).await?;
    if let Some(job) = state.export_jobs.lock().await.get_mut(&job_id) {
        job.status = "canceled".into();
        job.progress = 1.0;
    }
    Ok(())
}

#[tauri::command]
pub async fn commit_edit(
    state: State<'_, Arc<AppState>>,
    project_id: Uuid,
    expected_revision: u64,
    command: Value,
) -> AppResult<UiEditResult> {
    let view = state.editor.project_view(project_id).await?;
    let command = parse_editor_command(command, active_timeline_id(&view))?;
    let result = state
        .editor
        .commit_edit(project_id, expected_revision, command)
        .await?;
    let view = state.editor.project_view(project_id).await?;
    Ok(ui_edit_result(&view, result.receipt))
}

#[tauri::command]
pub async fn preview_edit(
    state: State<'_, Arc<AppState>>,
    project_id: Uuid,
    expected_revision: u64,
    command: Value,
) -> AppResult<UiPreviewEditResult> {
    let view = state.editor.project_view(project_id).await?;
    let command = parse_editor_command(command, active_timeline_id(&view))?;
    let result = state
        .editor
        .preview_edit(project_id, expected_revision, command)
        .await?;
    let mut view = state.editor.project_view(project_id).await?;
    view.snapshot = result.snapshot;
    Ok(ui_preview_edit_result(
        &view,
        result.receipt,
        result.expected_revision,
    ))
}

#[tauri::command]
pub async fn get_project(
    state: State<'_, Arc<AppState>>,
    project_id: String,
) -> AppResult<ProjectDocument> {
    let project_id = parse_uuid(&project_id, "projectId")?;
    let view = state.editor.project_view(project_id).await?;
    Ok(project_document(&view))
}

#[tauri::command]
pub async fn place_asset(
    state: State<'_, Arc<AppState>>,
    project_id: String,
    expected_revision: u64,
    asset_id: String,
    track_id: Option<String>,
    start_frame: i64,
) -> AppResult<UiEditResult> {
    let project_id = parse_uuid(&project_id, "projectId")?;
    let view = state.editor.project_view(project_id).await?;
    let command = place_asset_command(&view, &asset_id, track_id.as_deref(), start_frame)?;
    let result = state
        .editor
        .commit_edit(project_id, expected_revision, command)
        .await?;
    let view = state.editor.project_view(project_id).await?;
    Ok(ui_edit_result(&view, result.receipt))
}

#[tauri::command]
pub async fn close_project(state: State<'_, Arc<AppState>>, project_id: String) -> AppResult<()> {
    let project_id = parse_uuid(&project_id, "projectId")?;
    state.editor.close_project(project_id).await?;
    Ok(())
}

#[tauri::command]
pub async fn decode_preview_frame(
    state: State<'_, Arc<AppState>>,
    path: String,
    time_seconds: Option<f64>,
    max_width: Option<u32>,
    max_height: Option<u32>,
) -> AppResult<DecodePreviewFrameResult> {
    let micros = (time_seconds.unwrap_or(0.0) * 1_000_000.0).round() as i64;
    let time = palmier_media::MediaTime::from_micros(micros.max(0))?;
    let request = PausedFrameRequest {
        path: PathBuf::from(path),
        stream_index: None,
        time,
        max_width: max_width.unwrap_or(1280).max(1),
        max_height: max_height.unwrap_or(1280).max(1),
        allow_upscale: false,
        output: FrameOutput::Jpeg { quality: 85 },
    };
    let frame = state.editor.decode_paused_frame(request).await?;
    let (mime_type, bytes) = match frame.data {
        DecodedFrameData::Jpeg { bytes, .. } => ("image/jpeg".to_owned(), bytes),
        DecodedFrameData::Rgba { bytes } => ("application/octet-stream".to_owned(), bytes),
    };
    Ok(DecodePreviewFrameResult {
        width: frame.width,
        height: frame.height,
        mime_type,
        data_base64: BASE64.encode(bytes),
    })
}

#[tauri::command]
pub async fn render_preview_frame(
    state: State<'_, Arc<AppState>>,
    project_id: String,
    frame: u64,
    max_width: Option<u32>,
    max_height: Option<u32>,
) -> AppResult<DecodePreviewFrameResult> {
    let project_id = parse_uuid(&project_id, "projectId")?;
    let view = state.editor.project_view(project_id).await?;
    let source_size = active_timeline(&view)?;
    let width = max_width.unwrap_or(1280).max(1);
    let height = max_height.unwrap_or(720).max(1);
    let output_size = fit_size(
        u32::try_from(source_size.width)
            .map_err(|_| AppError::message("timeline width is invalid"))?,
        u32::try_from(source_size.height)
            .map_err(|_| AppError::message("timeline height is invalid"))?,
        width,
        height,
    );
    let render = prepared_render(&state, &view, output_size).await?;
    let source = Arc::clone(&render.source);
    let frame = frame.min(render.plan.duration_frames.saturating_sub(1));
    let rendered = tokio::task::spawn_blocking(move || source.render_frame(frame))
        .await
        .map_err(|error| AppError::message(format!("preview render task failed: {error}")))??;
    let jpeg = encode_jpeg(&rendered, 85)?;
    Ok(DecodePreviewFrameResult {
        width: rendered.width,
        height: rendered.height,
        mime_type: "image/jpeg".into(),
        data_base64: BASE64.encode(jpeg),
    })
}

#[tauri::command]
pub async fn decode_asset_preview(
    state: State<'_, Arc<AppState>>,
    project_id: String,
    asset_id: String,
    time_seconds: Option<f64>,
    max_width: Option<u32>,
    max_height: Option<u32>,
) -> AppResult<DecodePreviewFrameResult> {
    let project_id = parse_uuid(&project_id, "projectId")?;
    let view = state.editor.project_view(project_id).await?;
    let path = media_file_path(&view, &asset_id)?;
    let micros = (time_seconds.unwrap_or(0.0) * 1_000_000.0).round() as i64;
    let time = palmier_media::MediaTime::from_micros(micros.max(0))?;
    let request = PausedFrameRequest {
        path,
        stream_index: None,
        time,
        max_width: max_width.unwrap_or(1280).max(1),
        max_height: max_height.unwrap_or(720).max(1),
        allow_upscale: false,
        output: FrameOutput::Jpeg { quality: 85 },
    };
    let frame = state.editor.decode_paused_frame(request).await?;
    let (mime_type, bytes) = match frame.data {
        DecodedFrameData::Jpeg { bytes, .. } => ("image/jpeg".to_owned(), bytes),
        DecodedFrameData::Rgba { bytes } => ("application/octet-stream".to_owned(), bytes),
    };
    Ok(DecodePreviewFrameResult {
        width: frame.width,
        height: frame.height,
        mime_type,
        data_base64: BASE64.encode(bytes),
    })
}

#[tauri::command]
pub async fn capture_frame(
    state: State<'_, Arc<AppState>>,
    project_id: String,
    timeline_frame: Option<i64>,
    media_ref: Option<String>,
    source_seconds: Option<f64>,
) -> AppResult<Vec<MediaAsset>> {
    let project_id = parse_uuid(&project_id, "projectId")?;
    let view = state.editor.project_view(project_id).await?;
    let jpeg = match (
        timeline_frame,
        media_ref.as_deref(),
        source_seconds,
    ) {
        (Some(frame), None, None) => {
            let timeline = active_timeline(&view)?;
            let output_size = (
                u32::try_from(timeline.width).unwrap_or(1920).max(1),
                u32::try_from(timeline.height).unwrap_or(1080).max(1),
            );
            let render = prepared_render(&state, &view, output_size).await?;
            let source = Arc::clone(&render.source);
            let frame_index = u64::try_from(frame.max(0))
                .map_err(|_| AppError::message("timelineFrame is out of range"))?
                .min(render.plan.duration_frames.saturating_sub(1));
            let rendered = tokio::task::spawn_blocking(move || source.render_frame(frame_index))
                .await
                .map_err(|error| {
                    AppError::message(format!("capture render task failed: {error}"))
                })??;
            encode_jpeg(&rendered, 90)?
        }
        (None, Some(asset_id), Some(seconds)) => {
            let path = media_file_path(&view, asset_id)?;
            let micros = (seconds * 1_000_000.0).round() as i64;
            let time = palmier_media::MediaTime::from_micros(micros.max(0))?;
            let frame = state
                .editor
                .decode_paused_frame(PausedFrameRequest {
                    path,
                    stream_index: None,
                    time,
                    max_width: 1920,
                    max_height: 1080,
                    allow_upscale: true,
                    output: FrameOutput::Jpeg { quality: 90 },
                })
                .await?;
            match frame.data {
                DecodedFrameData::Jpeg { bytes, .. } => bytes,
                _ => {
                    return Err(AppError::message(
                        "capture_frame expected JPEG decode output",
                    ));
                }
            }
        }
        _ => {
            return Err(AppError::message(
                "pass timelineFrame alone, or mediaRef with sourceSeconds",
            ));
        }
    };
    let temp_path = std::env::temp_dir().join(format!("palmier-capture-{}.jpg", Uuid::new_v4()));
    tokio::fs::write(&temp_path, &jpeg)
        .await
        .map_err(|error| AppError::message(format!("write capture: {error}")))?;
    let result = import_media_paths(&state, project_id, vec![temp_path.clone()]).await;
    let _ = tokio::fs::remove_file(&temp_path).await;
    result
}

#[tauri::command]
pub async fn render_preview_audio(
    state: State<'_, Arc<AppState>>,
    project_id: String,
    start_frame: u64,
    frame_count: u64,
) -> AppResult<PreviewAudio> {
    let project_id = parse_uuid(&project_id, "projectId")?;
    let view = state.editor.project_view(project_id).await?;
    let timeline = active_timeline(&view)?;
    let fps = f64::from(timeline.fps.max(1));
    let output_size = fit_size(
        u32::try_from(timeline.width).unwrap_or(1920).max(1),
        u32::try_from(timeline.height).unwrap_or(1080).max(1),
        1280,
        720,
    );
    let render = prepared_render(&state, &view, output_size).await?;
    let start_seconds = start_frame as f64 / fps;
    let duration_seconds = (frame_count.max(1) as f64 / fps).max(1.0 / fps);
    let sample_rate = 48_000_u32;
    let channels = 2_u16;
    let start_sample = (start_seconds * f64::from(sample_rate)).floor().max(0.0) as u64;
    let sample_count = (duration_seconds * f64::from(sample_rate)).ceil().max(1.0) as usize;
    let source = Arc::clone(&render.source);
    let audio = tokio::task::spawn_blocking(move || {
        source.render_audio(start_sample, sample_count, sample_rate, channels)
    })
    .await
    .map_err(|error| AppError::message(format!("preview audio task failed: {error}")))??;
    Ok(PreviewAudio {
        sample_rate,
        channels: audio.channels,
        samples_base64: f32_samples_to_base64(&audio.samples),
    })
}

#[tauri::command]
pub async fn decode_asset_audio(
    state: State<'_, Arc<AppState>>,
    project_id: String,
    asset_id: String,
    time_seconds: Option<f64>,
    duration_seconds: Option<f64>,
) -> AppResult<PreviewAudio> {
    let project_id = parse_uuid(&project_id, "projectId")?;
    let view = state.editor.project_view(project_id).await?;
    let path = media_file_path(&view, &asset_id)?;
    let start = time_seconds.unwrap_or(0.0).max(0.0);
    let duration = duration_seconds.unwrap_or(0.5).max(1.0 / 48_000.0);
    let sample_rate = 48_000_u32;
    let channels = 2_u16;
    let pcm = tokio::task::spawn_blocking(move || {
        decode_pcm_range(&path, start, duration, sample_rate, channels)
    })
    .await
    .map_err(|error| AppError::message(format!("preview audio task failed: {error}")))??;
    Ok(PreviewAudio {
        sample_rate: pcm.sample_rate,
        channels: pcm.channels,
        samples_base64: f32_samples_to_base64(&pcm.samples),
    })
}

async fn load_provider_settings(state: &AppState) -> AppResult<ProviderSettings> {
    let credentials = state.generation.credentials();
    let fal = credentials.get_secret(FAL_API_KEY);
    let replicate = credentials.get_secret(REPLICATE_API_TOKEN);
    let unavailable_reason = fal
        .as_ref()
        .err()
        .or_else(|| replicate.as_ref().err())
        .map(ToString::to_string);
    Ok(ProviderSettings {
        fal_key: String::new(),
        replicate_key: String::new(),
        fal_configured: fal.ok().flatten().is_some(),
        replicate_configured: replicate.ok().flatten().is_some(),
        unavailable_reason,
    })
}

fn set_or_clear_secret(
    credentials: &dyn palmier_generation::CredentialStore,
    key: &str,
    value: &str,
) -> AppResult<()> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Ok(());
    }
    credentials.set_secret(key, trimmed)?;
    Ok(())
}

fn map_job_status(state: &JobState) -> String {
    match state {
        JobState::Preparing => "preparing".into(),
        JobState::Running | JobState::Downloading => "running".into(),
        JobState::Ready => "completed".into(),
        JobState::Failed => "failed".into(),
        JobState::Cancelled => "canceled".into(),
    }
}

fn export_extension(request: &UiExportRequest) -> &'static str {
    match request.destination.as_str() {
        "timeline" => match request.timeline_format.to_ascii_uppercase().as_str() {
            "XMEML" => "xml",
            _ => "fcpxml",
        },
        "project" => "palmier",
        _ if request.codec.eq_ignore_ascii_case("ProRes") => "mov",
        _ => "mp4",
    }
}

fn completed_export_job(project_id: Uuid, filename: String) -> AppResult<UiExportJob> {
    Ok(UiExportJob {
        id: Uuid::new_v4().to_string(),
        filename,
        progress: 1.0,
        status: "completed".into(),
        created_at: Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        error: None,
        project_id: Some(project_id.to_string()),
    })
}

fn apply_export_state(job: &mut UiExportJob, state: &ExportState) {
    match state {
        ExportState::Queued => {
            job.status = "waiting".into();
            job.progress = 0.0;
        }
        ExportState::Running { progress } => {
            job.status = match progress.phase {
                palmier_media::ExportPhase::Preflight => "preparing",
                palmier_media::ExportPhase::Encoding | palmier_media::ExportPhase::Finalizing => {
                    "running"
                }
            }
            .into();
            job.progress = f64::from(progress.fraction);
        }
        ExportState::Completed { .. } => {
            job.status = "completed".into();
            job.progress = 1.0;
        }
        ExportState::Failed { message } => {
            job.status = "failed".into();
            job.progress = 1.0;
            job.error = Some(message.clone());
        }
        ExportState::Cancelled => {
            job.status = "canceled".into();
            job.progress = 1.0;
        }
    }
}

fn active_timeline_id(view: &ProjectView) -> String {
    view.snapshot
        .project
        .active_timeline_id()
        .map(str::to_owned)
        .or_else(|| {
            view.snapshot
                .project
                .timelines
                .first()
                .map(|timeline| timeline.id.clone())
        })
        .unwrap_or_default()
}

fn parse_editor_command(value: Value, timeline_id: String) -> AppResult<EditorCommand> {
    let value = with_timeline_id(value, &timeline_id);
    serde_json::from_value(value.clone())
        .or_else(|_| serde_json::from_value(duplicate_case_keys(value.clone())))
        .map_err(|error| AppError::message(format!("invalid edit command: {error}")))
}

fn with_timeline_id(mut value: Value, timeline_id: &str) -> Value {
    let Some(object) = value.as_object_mut() else {
        return value;
    };
    let tag = object
        .get("command")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    if tag == "undo" || tag == "redo" || timeline_id.is_empty() {
        return value;
    }
    if !object.contains_key("timelineId") && !object.contains_key("timeline_id") {
        object.insert(
            "timelineId".into(),
            Value::String(timeline_id.to_owned()),
        );
        object.insert(
            "timeline_id".into(),
            Value::String(timeline_id.to_owned()),
        );
    }
    value
}

fn duplicate_case_keys(value: Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut out = serde_json::Map::new();
            for (key, child) in map {
                let child = duplicate_case_keys(child);
                let snake = camel_to_snake(&key);
                let camel = snake_to_camel(&key);
                out.insert(key, child.clone());
                out.insert(snake, child.clone());
                out.insert(camel, child);
            }
            Value::Object(out)
        }
        Value::Array(items) => Value::Array(items.into_iter().map(duplicate_case_keys).collect()),
        other => other,
    }
}

fn camel_to_snake(input: &str) -> String {
    let mut out = String::new();
    for (index, ch) in input.chars().enumerate() {
        if ch.is_uppercase() {
            if index > 0 {
                out.push('_');
            }
            out.extend(ch.to_lowercase());
        } else {
            out.push(ch);
        }
    }
    out
}

fn snake_to_camel(input: &str) -> String {
    let mut out = String::new();
    let mut upper = false;
    for ch in input.chars() {
        if ch == '_' {
            upper = true;
            continue;
        }
        if upper {
            out.extend(ch.to_uppercase());
            upper = false;
        } else {
            out.push(ch);
        }
    }
    out
}

fn place_asset_command(
    view: &ProjectView,
    asset_id: &str,
    requested_track_id: Option<&str>,
    start_frame: i64,
) -> AppResult<EditorCommand> {
    let timeline = active_timeline(view)?;
    let media = view
        .snapshot
        .media_manifest
        .entries
        .iter()
        .find(|entry| entry.id == asset_id)
        .ok_or_else(|| AppError::message(format!("media not found: {asset_id}")))?;
    let start_frame = start_frame.max(0);
    let duration = media_duration_frames(media.duration, timeline.fps, media.media_type);
    let primary_track = select_compatible_track(timeline, media.media_type, requested_track_id)?;
    let link_group_id = if media.media_type == ClipType::Video && media.has_audio == Some(true) {
        Some(palmier_core::new_id())
    } else {
        None
    };
    let mut video_clip = Clip::new(asset_id, start_frame, duration);
    video_clip.media_type = media.media_type;
    video_clip.source_clip_type = media.media_type;
    video_clip.link_group_id = link_group_id.clone();
    video_clip.fit_visual_to_canvas(
        media.source_width,
        media.source_height,
        timeline.width,
        timeline.height,
    );
    let mut commands = vec![EditorCommand::AddClips {
        timeline_id: timeline.id.clone(),
        track_id: primary_track.id.clone(),
        start_frame,
        clips: vec![video_clip],
        mode: AddMode::Overwrite,
    }];
    if let Some(link_group_id) = link_group_id {
        if let Some(audio_track) = timeline
            .tracks
            .iter()
            .find(|track| track.track_type == ClipType::Audio)
        {
            let mut audio_clip = Clip::new(asset_id, start_frame, duration);
            audio_clip.media_type = ClipType::Audio;
            audio_clip.source_clip_type = media.media_type;
            audio_clip.link_group_id = Some(link_group_id);
            commands.push(EditorCommand::AddClips {
                timeline_id: timeline.id.clone(),
                track_id: audio_track.id.clone(),
                start_frame,
                clips: vec![audio_clip],
                mode: AddMode::Overwrite,
            });
        }
    }
    if commands.len() == 1 {
        return Ok(commands.remove(0));
    }
    Ok(EditorCommand::Batch {
        timeline_id: timeline.id.clone(),
        commands,
    })
}

fn select_compatible_track<'a>(
    timeline: &'a palmier_core::Timeline,
    clip_type: ClipType,
    requested_track_id: Option<&str>,
) -> AppResult<&'a palmier_core::Track> {
    if let Some(track_id) = requested_track_id {
        if let Some(track) = timeline
            .tracks
            .iter()
            .find(|track| track.id == track_id && track.track_type.is_compatible_with(clip_type))
        {
            return Ok(track);
        }
    }
    timeline
        .tracks
        .iter()
        .find(|track| track.track_type.is_compatible_with(clip_type))
        .ok_or_else(|| AppError::message("timeline has no compatible track"))
}

fn media_duration_frames(duration: f64, fps: i32, media_type: ClipType) -> i64 {
    if duration.is_finite() && duration > 0.0 && fps > 0 {
        return (duration * f64::from(fps)).round().max(1.0) as i64;
    }
    let fallback_seconds = if media_type == ClipType::Image { 4 } else { 5 };
    i64::from(fps.max(1)) * fallback_seconds
}

fn media_file_path(view: &ProjectView, asset_id: &str) -> AppResult<PathBuf> {
    let entry = view
        .snapshot
        .media_manifest
        .entries
        .iter()
        .find(|entry| entry.id == asset_id)
        .ok_or_else(|| AppError::message(format!("media not found: {asset_id}")))?;
    Ok(resolve_media_path(
        &entry.source,
        view.summary.path.as_deref(),
    )?)
}

fn f32_samples_to_base64(samples: &[f32]) -> String {
    let mut bytes = Vec::with_capacity(samples.len() * 4);
    for sample in samples {
        bytes.extend_from_slice(&sample.to_le_bytes());
    }
    BASE64.encode(bytes)
}

async fn prepared_render(
    state: &AppState,
    view: &ProjectView,
    output_size: (u32, u32),
) -> AppResult<Arc<PreparedProjectRender>> {
    {
        let cache = state.render_cache.lock().await;
        if let Some(entry) = cache.get(&view.summary.project_id)
            && entry.revision == view.summary.revision
            && entry.width == output_size.0
            && entry.height == output_size.1
        {
            return Ok(Arc::clone(&entry.render));
        }
    }
    let render = Arc::new(
        prepare_project_render(
            &view.snapshot.project,
            &view.snapshot.media_manifest,
            view.summary.path.as_deref(),
            view.summary.active_timeline_id.as_deref(),
            Some(output_size),
        )
        .await?,
    );
    state.render_cache.lock().await.insert(
        view.summary.project_id,
        RenderCacheEntry {
            revision: view.summary.revision,
            width: output_size.0,
            height: output_size.1,
            render: Arc::clone(&render),
        },
    );
    Ok(render)
}

fn active_timeline(view: &ProjectView) -> AppResult<&palmier_core::Timeline> {
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
        .ok_or_else(|| AppError::message("project has no active timeline"))
}

fn export_size(view: &ProjectView, resolution: &str) -> AppResult<(u32, u32)> {
    let timeline = active_timeline(view)?;
    let width = u32::try_from(timeline.width)
        .map_err(|_| AppError::message("timeline width is invalid"))?;
    let height = u32::try_from(timeline.height)
        .map_err(|_| AppError::message("timeline height is invalid"))?;
    let size = match resolution {
        "1080p" => fit_size(width, height, 1920, 1080),
        "720p" => fit_size(width, height, 1280, 720),
        "timeline" => (width, height),
        other => {
            return Err(AppError::message(format!(
                "unsupported export resolution: {other}"
            )));
        }
    };
    Ok((even(size.0), even(size.1)))
}

fn fit_size(width: u32, height: u32, maximum_width: u32, maximum_height: u32) -> (u32, u32) {
    if width == 0 || height == 0 {
        return (maximum_width.max(1), maximum_height.max(1));
    }
    let scale = (maximum_width as f64 / width as f64).min(maximum_height as f64 / height as f64);
    (
        (width as f64 * scale).round().max(1.0) as u32,
        (height as f64 * scale).round().max(1.0) as u32,
    )
}

fn even(value: u32) -> u32 {
    if value.is_multiple_of(2) {
        value.max(2)
    } else {
        value.saturating_sub(1).max(2)
    }
}

async fn video_encoder_name(codec: &str) -> AppResult<String> {
    let capabilities = discover_codec_capabilities().await?;
    let (codec_id, preferred) = match codec {
        "H.264" => ("h264", ["libx264", "h264_v4l2m2m"].as_slice()),
        "HEVC" => ("hevc", ["libx265", "hevc_v4l2m2m"].as_slice()),
        "ProRes" => ("prores", ["prores_ks", "prores_aw", "prores"].as_slice()),
        other => return Err(AppError::message(format!("unsupported codec: {other}"))),
    };
    for name in preferred {
        if capabilities
            .codecs
            .iter()
            .any(|candidate| candidate.can_encode && candidate.name == *name)
        {
            return Ok((*name).to_owned());
        }
    }
    capabilities
        .codecs
        .iter()
        .find(|candidate| candidate.can_encode && candidate.codec_id == codec_id)
        .map(|candidate| candidate.name.clone())
        .ok_or_else(|| AppError::message(format!("{codec} encoder is unavailable")))
}

fn pick_export_path(app: &AppHandle, filename: &str, extension: &str) -> AppResult<PathBuf> {
    let picked = app
        .dialog()
        .file()
        .add_filter("Export", &[extension])
        .set_file_name(filename)
        .blocking_save_file();
    match picked {
        Some(path) => path
            .into_path()
            .map_err(|error| AppError::message(format!("resolve export path: {error}"))),
        None => Err(AppError::message("export canceled")),
    }
}

async fn write_atomic(destination: &Path, bytes: &[u8]) -> AppResult<()> {
    let parent = destination
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let filename = destination
        .file_name()
        .ok_or_else(|| AppError::message("export destination has no filename"))?;
    let stage = parent.join(format!(
        ".{}.{}.partial",
        filename.to_string_lossy(),
        Uuid::new_v4()
    ));
    tokio::fs::write(&stage, bytes)
        .await
        .map_err(|error| AppError::message(format!("write export stage: {error}")))?;
    if let Err(error) = tokio::fs::rename(&stage, destination).await {
        let _ = tokio::fs::remove_file(&stage).await;
        return Err(AppError::message(format!("install export: {error}")));
    }
    Ok(())
}

fn fcpxml_document(timeline: &palmier_core::Timeline) -> String {
    let mut clips = String::new();
    for track in &timeline.tracks {
        for clip in &track.clips {
            clips.push_str(&format!(
                "<asset-clip name=\"{}\" ref=\"{}\" offset=\"{}/{}s\" duration=\"{}/{}s\" start=\"{}/{}s\"/>",
                xml_escape(&clip.media_ref),
                xml_escape(&clip.media_ref),
                clip.start_frame,
                timeline.fps,
                clip.duration_frames,
                timeline.fps,
                clip.trim_start_frame,
                timeline.fps,
            ));
        }
    }
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><fcpxml version=\"1.11\"><resources/><library><event name=\"Palmier\"><project name=\"{}\"><sequence format=\"r1\" duration=\"{}/{}s\"><spine>{clips}</spine></sequence></project></event></library></fcpxml>",
        xml_escape(&timeline.name),
        timeline.total_frames(),
        timeline.fps,
    )
}

fn xmeml_document(timeline: &palmier_core::Timeline) -> String {
    let mut tracks = String::new();
    for track in &timeline.tracks {
        let mut items = String::new();
        for clip in &track.clips {
            items.push_str(&format!(
                "<clipitem id=\"{}\"><name>{}</name><start>{}</start><end>{}</end><in>{}</in><out>{}</out></clipitem>",
                xml_escape(&clip.id),
                xml_escape(&clip.media_ref),
                clip.start_frame,
                clip.end_frame(),
                clip.trim_start_frame,
                clip.trim_start_frame.saturating_add(clip.duration_frames),
            ));
        }
        tracks.push_str(&format!("<track>{items}</track>"));
    }
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><xmeml version=\"5\"><sequence><name>{}</name><duration>{}</duration><rate><timebase>{}</timebase><ntsc>FALSE</ntsc></rate><media><video>{tracks}</video></media></sequence></xmeml>",
        xml_escape(&timeline.name),
        timeline.total_frames(),
        timeline.fps,
    )
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn pick_project_path(app: &AppHandle) -> AppResult<PathBuf> {
    // .palmier packages are directories, so use a folder picker.
    let dialog = app.dialog().file().set_directory(default_projects_dir());
    let picked = dialog.blocking_pick_folder();
    let path = match picked {
        Some(path) => path
            .into_path()
            .map_err(|error| AppError::message(format!("resolve project path: {error}")))?,
        None => return Err(AppError::message("open project canceled")),
    };
    if !is_project_package_path(&path) {
        return Err(AppError::message(format!(
            "select a .{PROJECT_FILE_EXTENSION} project folder"
        )));
    }
    Ok(path)
}

fn pick_import_paths(app: &AppHandle) -> AppResult<Vec<PathBuf>> {
    let picked = app
        .dialog()
        .file()
        .add_filter(
            "Media",
            &[
                "mp4", "mov", "m4v", "mp3", "wav", "aac", "m4a", "png", "jpg", "jpeg", "webp",
                "gif",
            ],
        )
        .add_filter("All Files", &["*"])
        .blocking_pick_files();
    let Some(files) = picked else {
        return Ok(Vec::new());
    };
    files
        .into_iter()
        .map(|path| {
            path.into_path()
                .map_err(|error| AppError::message(format!("resolve import path: {error}")))
        })
        .collect()
}

fn default_projects_dir() -> PathBuf {
    if let Some(home) = std::env::var_os("HOME") {
        return PathBuf::from(home).join("Palmier Projects");
    }
    PathBuf::from("Palmier Projects")
}

async fn unique_destination(path: PathBuf) -> AppResult<PathBuf> {
    if tokio::fs::metadata(&path).await.is_err() {
        return Ok(path);
    }
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let stem = path
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_else(|| "Untitled".into());
    for index in 2..10_000 {
        let candidate = parent.join(format!("{stem}-{index}.{PROJECT_FILE_EXTENSION}"));
        if tokio::fs::metadata(&candidate).await.is_err() {
            return Ok(candidate);
        }
    }
    Err(AppError::message(
        "could not allocate a unique project path",
    ))
}

fn parse_uuid(value: &str, field: &str) -> AppResult<Uuid> {
    Uuid::parse_str(value).map_err(|_| AppError::message(format!("invalid {field}: {value}")))
}
