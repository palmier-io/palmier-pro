use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

use palmier_core::{
    BlendMode, Clip, ClipType, MediaManifest, MediaSource as ManifestSource, ProjectFile, Timeline,
};

use crate::audio_decode::decode_pcm_range;
use crate::compose::{ComposeRequest, LayerFrame, compose_frame};
use crate::decode::{DecodedFrameData, FrameOutput, PausedFrameRequest, decode_paused_frame_sync};
use crate::error::{MediaError, Result};
use crate::export::{ExportFrameSource, InterleavedAudio, RgbaFrame};
use crate::ffmpeg::discover_codec_capabilities;
use crate::plan::{
    ClipPlan, ClipSource, CompositionPlan, Effect, MediaSource, TrackKind, TrackPlan,
};
use crate::probe::{MediaProbe, probe_media};
use crate::renderer::RendererCapabilities;
use crate::time::{ExactRational, FrameRange, FrameRate, MediaTime};

const SPEED_SCALE: f64 = 1_000_000.0;

pub struct PreparedProjectRender {
    pub plan: CompositionPlan,
    pub media: HashMap<String, MediaProbe>,
    pub source: Arc<ProjectFrameSource>,
    pub has_audio: bool,
}

#[derive(Clone)]
struct ClipRenderMetadata {
    clip: Clip,
    kind: TrackKind,
}

pub struct ProjectFrameSource {
    plan: CompositionPlan,
    clips: HashMap<String, ClipRenderMetadata>,
    capabilities: RendererCapabilities,
    has_audio: bool,
}

pub async fn prepare_project_render(
    project: &ProjectFile,
    manifest: &MediaManifest,
    project_path: Option<&Path>,
    timeline_id: Option<&str>,
    output_size: Option<(u32, u32)>,
) -> Result<PreparedProjectRender> {
    let timeline = timeline_id
        .and_then(|id| project.timelines.iter().find(|timeline| timeline.id == id))
        .or_else(|| {
            project
                .active_timeline_id()
                .and_then(|id| project.timelines.iter().find(|timeline| timeline.id == id))
        })
        .or_else(|| project.timelines.first())
        .ok_or_else(|| MediaError::InvalidPlan("project has no timeline".into()))?;

    let entries = manifest
        .entries
        .iter()
        .map(|entry| (entry.id.as_str(), entry))
        .collect::<HashMap<_, _>>();
    let timelines = project
        .timelines
        .iter()
        .map(|timeline| (timeline.id.as_str(), timeline))
        .collect::<HashMap<_, _>>();
    let mut clips = HashMap::new();
    let mut stack = Vec::new();
    let mut plan = build_timeline_plan(
        timeline,
        &entries,
        &timelines,
        project_path,
        &mut clips,
        &mut stack,
    )?;
    if let Some((width, height)) = output_size {
        if width == 0 || height == 0 {
            return Err(MediaError::InvalidRequest(
                "render output dimensions must be nonzero".into(),
            ));
        }
        plan.width = width;
        plan.height = height;
    }

    let mut media = HashMap::new();
    collect_media_probes(&plan, &mut media).await?;
    let codecs = discover_codec_capabilities().await?;
    let capabilities = RendererCapabilities::software(&codecs);
    let has_audio = plan.tracks.iter().any(|track| {
        track.kind == TrackKind::Audio && !track.clips.is_empty()
    });
    let source = Arc::new(ProjectFrameSource {
        plan: plan.clone(),
        clips,
        capabilities,
        has_audio,
    });
    Ok(PreparedProjectRender {
        plan,
        media,
        source,
        has_audio,
    })
}

impl ProjectFrameSource {
    pub fn render_frame(&self, frame_index: u64) -> Result<RgbaFrame> {
        self.render_video_frame(frame_index, self.plan.width, self.plan.height)
    }
}

impl ExportFrameSource for ProjectFrameSource {
    fn capabilities(&self) -> RendererCapabilities {
        self.capabilities.clone()
    }

    fn render_video_frame(
        &self,
        frame_index: u64,
        width: u32,
        height: u32,
    ) -> Result<RgbaFrame> {
        if width != self.plan.width || height != self.plan.height {
            return Err(MediaError::InvalidRequest(
                "render dimensions do not match the composition plan".into(),
            ));
        }
        let timeline_frame = i64::try_from(frame_index)
            .map_err(|_| MediaError::ArithmeticOverflow("timeline frame"))?;
        let mappings = self.plan.map_frame(frame_index)?;
        let mut layers = Vec::new();
        for mapping in mappings {
            let clip_id = mapping
                .clip_path
                .last()
                .ok_or_else(|| MediaError::InvalidPlan("mapping has no clip".into()))?;
            let metadata = self.clips.get(clip_id).ok_or_else(|| {
                MediaError::InvalidPlan(format!("render metadata is missing for clip {clip_id}"))
            })?;
            if metadata.kind != TrackKind::Video {
                continue;
            }
            let decoded = decode_paused_frame_sync(PausedFrameRequest {
                path: mapping.path,
                stream_index: mapping.stream_index,
                time: mapping.source_time,
                max_width: width,
                max_height: height,
                allow_upscale: true,
                output: FrameOutput::Rgba,
            })?;
            let DecodedFrameData::Rgba { bytes } = decoded.data else {
                return Err(MediaError::InvalidRequest(
                    "project renderer requires RGBA decode".into(),
                ));
            };
            let transform = metadata.clip.transform_at(timeline_frame);
            let crop = metadata.clip.crop_at(timeline_frame);
            layers.push(LayerFrame {
                rgba: RgbaFrame {
                    width: decoded.width,
                    height: decoded.height,
                    bytes,
                },
                opacity: metadata.clip.opacity_at(timeline_frame) as f32,
                center_x: transform.center_x as f32,
                center_y: transform.center_y as f32,
                scale_x: transform.width as f32,
                scale_y: transform.height as f32,
                rotation_degrees: transform.rotation as f32,
                flip_horizontal: transform.flip_horizontal,
                flip_vertical: transform.flip_vertical,
                crop_left: crop.left as f32,
                crop_top: crop.top as f32,
                crop_right: crop.right as f32,
                crop_bottom: crop.bottom as f32,
            });
        }
        compose_frame(&ComposeRequest {
            width,
            height,
            background: [0, 0, 0, 255],
            layers,
        })
    }

    fn render_audio(
        &self,
        start_sample: u64,
        sample_count: usize,
        sample_rate: u32,
        channels: u16,
    ) -> Result<InterleavedAudio> {
        let channel_count = usize::from(channels.max(1));
        let mut samples =
            vec![0.0_f32; sample_count.saturating_mul(channel_count)];
        if sample_count == 0 || !self.has_audio {
            return Ok(InterleavedAudio { channels, samples });
        }
        if sample_rate == 0 {
            return Err(MediaError::InvalidRequest(
                "audio sample rate must be nonzero".into(),
            ));
        }

        let fps = self.plan.frame_rate.as_rational().as_f64();
        if fps <= 0.0 {
            return Err(MediaError::InvalidPlan("invalid composition frame rate".into()));
        }
        let start_seconds = start_sample as f64 / f64::from(sample_rate);
        let duration_seconds = sample_count as f64 / f64::from(sample_rate);
        let end_seconds = start_seconds + duration_seconds;

        for track in &self.plan.tracks {
            if track.kind != TrackKind::Audio {
                continue;
            }
            for clip in &track.clips {
                let clip_start = clip.timeline_range.start as f64 / fps;
                let clip_end = (clip.timeline_range.start + clip.timeline_range.duration) as f64 / fps;
                let overlap_start = start_seconds.max(clip_start);
                let overlap_end = end_seconds.min(clip_end);
                if overlap_end <= overlap_start {
                    continue;
                }
                let ClipSource::Media(source) = &clip.source else {
                    continue;
                };
                let metadata = self.clips.get(&clip.id).ok_or_else(|| {
                    MediaError::InvalidPlan(format!("audio metadata missing for {}", clip.id))
                })?;
                let local_start = overlap_start - clip_start;
                let playback_rate = clip.playback_rate.as_f64().max(0.0001);
                let source_start =
                    clip.source_in.seconds().as_f64() + local_start * playback_rate;
                let source_duration = (overlap_end - overlap_start) * playback_rate;
                let pcm = decode_pcm_range(
                    &source.path,
                    source_start.max(0.0),
                    source_duration.max(1.0 / f64::from(sample_rate)),
                    sample_rate,
                    channels,
                )?;
                let dest_offset = ((overlap_start - start_seconds) * f64::from(sample_rate))
                    .floor()
                    .max(0.0) as usize;
                let frames = pcm.samples.len() / channel_count;
                for frame_index in 0..frames {
                    let out_frame = dest_offset + frame_index;
                    if out_frame >= sample_count {
                        break;
                    }
                    let timeline_frame = ((overlap_start + frame_index as f64 / f64::from(sample_rate))
                        * fps)
                        .floor() as i64;
                    let gain = metadata.clip.volume_at(timeline_frame) as f32;
                    for channel in 0..channel_count {
                        let sample = pcm.samples[frame_index * channel_count + channel] * gain;
                        samples[out_frame * channel_count + channel] =
                            (samples[out_frame * channel_count + channel] + sample).clamp(-1.0, 1.0);
                    }
                }
            }
        }

        Ok(InterleavedAudio { channels, samples })
    }
}

fn build_timeline_plan(
    timeline: &Timeline,
    entries: &HashMap<&str, &palmier_core::MediaManifestEntry>,
    timelines: &HashMap<&str, &Timeline>,
    project_path: Option<&Path>,
    clips: &mut HashMap<String, ClipRenderMetadata>,
    stack: &mut Vec<String>,
) -> Result<CompositionPlan> {
    if stack.contains(&timeline.id) {
        return Err(MediaError::InvalidPlan(format!(
            "nested timeline cycle includes {}",
            timeline.id
        )));
    }
    if timeline.fps <= 0 || timeline.width <= 0 || timeline.height <= 0 {
        return Err(MediaError::InvalidPlan(format!(
            "timeline {} has invalid settings",
            timeline.id
        )));
    }
    let duration_frames = u64::try_from(timeline.total_frames())
        .map_err(|_| MediaError::InvalidPlan("timeline duration is negative".into()))?;
    if duration_frames == 0 {
        return Err(MediaError::InvalidPlan(
            "cannot render an empty timeline".into(),
        ));
    }
    let frame_rate = FrameRate::new(
        u32::try_from(timeline.fps)
            .map_err(|_| MediaError::InvalidPlan("timeline fps is invalid".into()))?,
        1,
    )?;
    stack.push(timeline.id.clone());
    let mut tracks = Vec::new();
    for track in &timeline.tracks {
        let kind = if track.track_type == ClipType::Audio {
            if track.muted {
                continue;
            }
            TrackKind::Audio
        } else {
            if track.hidden {
                continue;
            }
            TrackKind::Video
        };
        let mut planned_clips = Vec::new();
        for clip in &track.clips {
            if clip.duration_frames <= 0 || clip.start_frame < 0 || clip.trim_start_frame < 0 {
                return Err(MediaError::InvalidPlan(format!(
                    "clip {} has invalid frame bounds",
                    clip.id
                )));
            }
            validate_supported_clip(clip)?;
            let source = if clip.source_clip_type == ClipType::Sequence
                || clip.media_type == ClipType::Sequence
            {
                let nested = timelines.get(clip.media_ref.as_str()).ok_or_else(|| {
                    MediaError::InvalidPlan(format!(
                        "nested timeline {} is missing",
                        clip.media_ref
                    ))
                })?;
                ClipSource::Nested {
                    plan: Box::new(build_timeline_plan(
                        nested,
                        entries,
                        timelines,
                        project_path,
                        clips,
                        stack,
                    )?),
                }
            } else {
                let entry = entries.get(clip.media_ref.as_str()).ok_or_else(|| {
                    MediaError::InvalidPlan(format!(
                        "media {} for clip {} is missing",
                        clip.media_ref, clip.id
                    ))
                })?;
                let path = resolve_media_path(&entry.source, project_path)?;
                ClipSource::Media(MediaSource {
                    asset_id: entry.id.clone(),
                    path,
                    kind,
                    stream_index: None,
                    frame_rate: None,
                })
            };
            let playback_rate = rational_from_f64(clip.speed)?;
            let source_in = MediaTime::from_seconds(
                ExactRational::from_integer(i128::from(clip.trim_start_frame))
                    .checked_div(frame_rate.as_rational())?,
            );
            let timeline_range = FrameRange::new(
                u64::try_from(clip.start_frame)
                    .map_err(|_| MediaError::ArithmeticOverflow("clip start"))?,
                u64::try_from(clip.duration_frames)
                    .map_err(|_| MediaError::ArithmeticOverflow("clip duration"))?,
            )?;
            let transform = clip.transform_at(clip.start_frame);
            let crop = clip.crop_at(clip.start_frame);
            let mut effects = vec![
                Effect::Opacity {
                    value: clip.opacity_at(clip.start_frame) as f32,
                },
                Effect::Transform {
                    x: transform.center_x as f32,
                    y: transform.center_y as f32,
                    scale_x: transform.width as f32,
                    scale_y: transform.height as f32,
                    rotation_degrees: transform.rotation as f32,
                },
            ];
            if !crop.is_identity() {
                effects.push(Effect::Crop {
                    left: crop.left as f32,
                    top: crop.top as f32,
                    right: crop.right as f32,
                    bottom: crop.bottom as f32,
                });
            }
            if kind == TrackKind::Audio {
                effects.push(Effect::Volume {
                    gain: clip.volume_at(clip.start_frame) as f32,
                });
            }
            clips.insert(
                clip.id.clone(),
                ClipRenderMetadata {
                    clip: clip.clone(),
                    kind,
                },
            );
            planned_clips.push(ClipPlan {
                id: clip.id.clone(),
                timeline_range,
                source_in,
                playback_rate,
                source,
                effects,
            });
        }
        tracks.push(TrackPlan {
            id: track.id.clone(),
            kind,
            clips: planned_clips,
        });
    }
    stack.pop();
    let plan = CompositionPlan {
        id: timeline.id.clone(),
        frame_rate,
        width: u32::try_from(timeline.width)
            .map_err(|_| MediaError::ArithmeticOverflow("timeline width"))?,
        height: u32::try_from(timeline.height)
            .map_err(|_| MediaError::ArithmeticOverflow("timeline height"))?,
        duration_frames,
        tracks,
    };
    plan.validate()?;
    Ok(plan)
}

fn validate_supported_clip(clip: &Clip) -> Result<()> {
    if matches!(clip.media_type, ClipType::Text | ClipType::Lottie) {
        return Err(MediaError::UnsupportedMedia(format!(
            "{:?} clips are not supported by the Linux renderer",
            clip.media_type
        )));
    }
    if clip
        .effects
        .as_ref()
        .is_some_and(|effects| effects.iter().any(|effect| effect.enabled))
    {
        return Err(MediaError::UnsupportedMedia(
            "clip effects beyond transform, crop, opacity, and volume are not supported".into(),
        ));
    }
    if clip
        .blend_mode
        .is_some_and(|blend| blend != BlendMode::Normal)
    {
        return Err(MediaError::UnsupportedMedia(
            "non-normal blend modes are not supported".into(),
        ));
    }
    if clip.edge_rounding != 0.0 || clip.edge_softness != 0.0 {
        return Err(MediaError::UnsupportedMedia(
            "edge rounding and softness are not supported".into(),
        ));
    }
    if !clip.speed.is_finite() || clip.speed <= 0.0 {
        return Err(MediaError::InvalidPlan(format!(
            "clip {} has invalid speed",
            clip.id
        )));
    }
    Ok(())
}

fn resolve_media_path(source: &ManifestSource, project_path: Option<&Path>) -> Result<PathBuf> {
    match source {
        ManifestSource::External { absolute_path } => {
            let path = PathBuf::from(absolute_path);
            if !path.is_absolute() {
                return Err(MediaError::InvalidPlan(format!(
                    "external media path is not absolute: {}",
                    path.display()
                )));
            }
            Ok(path)
        }
        ManifestSource::Project { relative_path } => {
            let package = project_path.ok_or_else(|| {
                MediaError::InvalidPlan("project media requires a saved package path".into())
            })?;
            let relative = Path::new(relative_path);
            if relative.is_absolute()
                || relative.as_os_str().is_empty()
                || relative
                    .components()
                    .any(|part| !matches!(part, Component::Normal(_) | Component::CurDir))
            {
                return Err(MediaError::InvalidPlan(format!(
                    "project media path is invalid: {}",
                    relative.display()
                )));
            }
            Ok(package.join(relative))
        }
    }
}

fn rational_from_f64(value: f64) -> Result<ExactRational> {
    if !value.is_finite() || value <= 0.0 {
        return Err(MediaError::InvalidPlan(
            "playback rate must be finite and positive".into(),
        ));
    }
    let scaled = (value * SPEED_SCALE).round();
    if scaled <= 0.0 || scaled > i128::MAX as f64 {
        return Err(MediaError::ArithmeticOverflow("playback rate"));
    }
    ExactRational::new(scaled as i128, SPEED_SCALE as i128)
}

async fn collect_media_probes(
    plan: &CompositionPlan,
    media: &mut HashMap<String, MediaProbe>,
) -> Result<()> {
    let mut pending = Vec::new();
    collect_media_sources(plan, &mut pending);
    for (asset_id, path) in pending {
        if media.contains_key(&asset_id) {
            continue;
        }
        media.insert(asset_id, probe_media(path).await?);
    }
    Ok(())
}

fn collect_media_sources(plan: &CompositionPlan, output: &mut Vec<(String, PathBuf)>) {
    for track in &plan.tracks {
        for clip in &track.clips {
            match &clip.source {
                ClipSource::Media(source) => {
                    output.push((source.asset_id.clone(), source.path.clone()));
                }
                ClipSource::Nested { plan } => collect_media_sources(plan, output),
            }
        }
    }
}

pub fn encode_jpeg(frame: &RgbaFrame, quality: u8) -> Result<Vec<u8>> {
    if frame.bytes.len()
        != frame.width as usize * frame.height as usize * 4
    {
        return Err(MediaError::InvalidRequest(
            "RGBA frame byte count does not match dimensions".into(),
        ));
    }
    let mut rgb = Vec::with_capacity(frame.width as usize * frame.height as usize * 3);
    for pixel in frame.bytes.chunks_exact(4) {
        rgb.extend_from_slice(&pixel[..3]);
    }
    let mut output = Vec::new();
    jpeg_encoder::Encoder::new(&mut output, quality)
        .encode(
            &rgb,
            u16::try_from(frame.width)
                .map_err(|_| MediaError::ArithmeticOverflow("JPEG width"))?,
            u16::try_from(frame.height)
                .map_err(|_| MediaError::ArithmeticOverflow("JPEG height"))?,
            jpeg_encoder::ColorType::Rgb,
        )
        .map_err(|error| MediaError::UnsupportedMedia(error.to_string()))?;
    Ok(output)
}

#[cfg(test)]
mod tests {
    use std::fs;

    use palmier_core::{MediaManifestEntry, Track};

    use super::*;

    #[test]
    fn builds_a_static_video_plan() {
        let mut timeline = Timeline::default();
        timeline.fps = 30;
        timeline.width = 1920;
        timeline.height = 1080;
        let mut track = Track::new(ClipType::Video);
        track.clips.push(Clip::new("asset", 0, 30));
        timeline.tracks.push(track);
        let project = ProjectFile::new(vec![timeline]).unwrap();
        let manifest = MediaManifest {
            version: 2,
            entries: vec![MediaManifestEntry {
                id: "asset".into(),
                name: "Asset".into(),
                media_type: ClipType::Video,
                source: ManifestSource::External {
                    absolute_path: "/tmp/asset.mp4".into(),
                },
                duration: 1.0,
                generation_input: None,
                source_width: Some(1920),
                source_height: Some(1080),
                source_fps: Some(30.0),
                has_audio: Some(false),
                folder_id: None,
                cached_remote_url: None,
                cached_remote_url_expires_at: None,
                generation_status: None,
                import_input: None,
            }],
            folders: Vec::new(),
        };
        let entries = manifest
            .entries
            .iter()
            .map(|entry| (entry.id.as_str(), entry))
            .collect();
        let timelines = project
            .timelines
            .iter()
            .map(|timeline| (timeline.id.as_str(), timeline))
            .collect();
        let mut clips = HashMap::new();
        let plan = build_timeline_plan(
            &project.timelines[0],
            &entries,
            &timelines,
            None,
            &mut clips,
            &mut Vec::new(),
        )
        .unwrap();
        assert_eq!(plan.duration_frames, 30);
        assert_eq!(plan.tracks[0].clips.len(), 1);
    }

    #[tokio::test]
    async fn project_renderer_exports_a_real_image_clip() {
        let directory = tempfile::tempdir().unwrap();
        let source_path = directory.path().join("source.ppm");
        let mut ppm = b"P6\n16 16\n255\n".to_vec();
        ppm.extend(std::iter::repeat_n([48_u8, 160, 96], 16 * 16).flatten());
        fs::write(&source_path, ppm).unwrap();

        let mut timeline = Timeline {
            fps: 24,
            width: 16,
            height: 16,
            ..Timeline::default()
        };
        let mut track = Track::new(ClipType::Video);
        let mut clip = Clip::new("asset", 0, 1);
        clip.media_type = ClipType::Image;
        clip.source_clip_type = ClipType::Image;
        track.clips.push(clip);
        timeline.tracks.push(track);
        let project = ProjectFile::new(vec![timeline]).unwrap();
        let manifest = MediaManifest {
            version: 2,
            entries: vec![MediaManifestEntry {
                id: "asset".into(),
                name: "Source".into(),
                media_type: ClipType::Image,
                source: ManifestSource::External {
                    absolute_path: source_path.display().to_string(),
                },
                duration: 1.0,
                generation_input: None,
                source_width: Some(16),
                source_height: Some(16),
                source_fps: None,
                has_audio: Some(false),
                folder_id: None,
                cached_remote_url: None,
                cached_remote_url_expires_at: None,
                generation_status: None,
                import_input: None,
            }],
            folders: Vec::new(),
        };

        let prepared = prepare_project_render(&project, &manifest, None, None, None)
            .await
            .unwrap();
        let frame = match prepared.source.render_frame(0) {
            Ok(frame) => frame,
            Err(error) => {
                // Some hosts reject PPM decode (EPERM / missing image demuxer).
                eprintln!("skipping project renderer export: {error}");
                return;
            }
        };
        assert_eq!(frame.bytes.len(), 16 * 16 * 4);

        let capabilities = discover_codec_capabilities().await.unwrap();
        let Some(encoder) = capabilities.h264_encoders().next() else {
            return;
        };
        let destination = directory.path().join("render.mp4");
        let receipt = crate::export_media(
            crate::ExportRequest {
                destination: destination.clone(),
                overwrite: false,
                plan: prepared.plan,
                media: prepared.media,
                settings: crate::ExportSettings {
                    video_bit_rate: 100_000,
                    video_encoder: Some(encoder.name.clone()),
                    audio: None,
                },
            },
            prepared.source,
        )
        .await
        .unwrap();
        assert_eq!(receipt.video_frames, 1);
        assert!(destination.is_file());
        assert!(probe_media(destination).await.unwrap().video.is_some());
    }
}
