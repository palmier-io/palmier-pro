use std::collections::{BTreeSet, HashMap};

use serde::{Deserialize, Serialize};

use crate::error::{MediaError, Result};
use crate::ffmpeg::{CodecCapabilities, CodecMediaType};
use crate::plan::{ClipSource, CompositionPlan, EffectKind, TrackKind};
use crate::probe::{AudioProbe, MediaProbe};
use crate::time::{ExactRational, FrameRate, MediaTime};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RendererCapabilities {
    pub supported_effects: BTreeSet<EffectKind>,
    pub video_decoder_codec_ids: BTreeSet<String>,
    pub audio_decoder_codec_ids: BTreeSet<String>,
    pub display_rotations: BTreeSet<u16>,
    pub max_width: u32,
    pub max_height: u32,
    pub supports_nested_compositions: bool,
    pub supports_display_mirroring: bool,
}

impl RendererCapabilities {
    pub fn software(codecs: &CodecCapabilities) -> Self {
        let mut video_decoder_codec_ids = BTreeSet::new();
        let mut audio_decoder_codec_ids = BTreeSet::new();
        for codec in codecs.codecs.iter().filter(|codec| codec.can_decode) {
            match codec.media_type {
                CodecMediaType::Video => {
                    video_decoder_codec_ids.insert(codec.codec_id.clone());
                }
                CodecMediaType::Audio => {
                    audio_decoder_codec_ids.insert(codec.codec_id.clone());
                }
                _ => {}
            }
        }
        Self {
            supported_effects: [
                EffectKind::Opacity,
                EffectKind::Transform,
                EffectKind::Crop,
                EffectKind::ColorAdjustment,
                EffectKind::Volume,
                EffectKind::Pan,
            ]
            .into_iter()
            .collect(),
            video_decoder_codec_ids,
            audio_decoder_codec_ids,
            display_rotations: [0, 90, 180, 270].into_iter().collect(),
            max_width: 16_384,
            max_height: 16_384,
            supports_nested_compositions: true,
            supports_display_mirroring: false,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PreflightLocation {
    pub composition_id: String,
    pub track_id: String,
    pub clip_id: String,
    pub asset_id: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum UnsupportedRenderReason {
    MissingProbe,
    MissingVideoStream,
    MissingAudioStream,
    VideoParametersUnavailable,
    AudioParametersUnavailable,
    VideoDecoderUnavailable {
        codec_id: String,
    },
    AudioDecoderUnavailable {
        codec_id: String,
    },
    DimensionsExceedLimit {
        width: u32,
        height: u32,
        max_width: u32,
        max_height: u32,
    },
    DisplayRotationUnsupported {
        degrees: i32,
    },
    DisplayMirroringUnsupported,
    SourceFrameRateMismatch {
        planned: FrameRate,
        probed: FrameRate,
    },
    SourceRangeExceedsMedia {
        source_end: MediaTime,
        media_duration: MediaTime,
    },
    EffectUnsupported {
        effect: EffectKind,
    },
    NestedCompositionUnsupported,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct UnsupportedRenderItem {
    pub location: PreflightLocation,
    pub reason: UnsupportedRenderReason,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RenderPreflightReport {
    pub unsupported: Vec<UnsupportedRenderItem>,
}

impl RenderPreflightReport {
    pub fn is_supported(&self) -> bool {
        self.unsupported.is_empty()
    }

    pub fn require_supported(&self) -> Result<()> {
        if self.is_supported() {
            Ok(())
        } else {
            Err(MediaError::UnsupportedRender(self.unsupported.len()))
        }
    }
}

pub fn preflight_render(
    plan: &CompositionPlan,
    capabilities: &RendererCapabilities,
    media: &HashMap<String, MediaProbe>,
) -> Result<RenderPreflightReport> {
    plan.validate()?;
    let mut report = RenderPreflightReport {
        unsupported: Vec::new(),
    };
    inspect_plan(plan, capabilities, media, &mut report)?;
    Ok(report)
}

fn inspect_plan(
    plan: &CompositionPlan,
    capabilities: &RendererCapabilities,
    media: &HashMap<String, MediaProbe>,
    report: &mut RenderPreflightReport,
) -> Result<()> {
    if plan.width > capabilities.max_width || plan.height > capabilities.max_height {
        report.unsupported.push(UnsupportedRenderItem {
            location: PreflightLocation {
                composition_id: plan.id.clone(),
                track_id: String::new(),
                clip_id: String::new(),
                asset_id: None,
            },
            reason: UnsupportedRenderReason::DimensionsExceedLimit {
                width: plan.width,
                height: plan.height,
                max_width: capabilities.max_width,
                max_height: capabilities.max_height,
            },
        });
    }
    for track in &plan.tracks {
        for clip in &track.clips {
            let base_location = PreflightLocation {
                composition_id: plan.id.clone(),
                track_id: track.id.clone(),
                clip_id: clip.id.clone(),
                asset_id: None,
            };
            for effect in &clip.effects {
                if !capabilities.supported_effects.contains(&effect.kind()) {
                    report.unsupported.push(UnsupportedRenderItem {
                        location: base_location.clone(),
                        reason: UnsupportedRenderReason::EffectUnsupported {
                            effect: effect.kind(),
                        },
                    });
                }
            }

            match &clip.source {
                ClipSource::Nested { plan: nested } => {
                    if !capabilities.supports_nested_compositions {
                        report.unsupported.push(UnsupportedRenderItem {
                            location: base_location,
                            reason: UnsupportedRenderReason::NestedCompositionUnsupported,
                        });
                    } else {
                        inspect_plan(nested, capabilities, media, report)?;
                    }
                }
                ClipSource::Media(source) => {
                    let location = PreflightLocation {
                        asset_id: Some(source.asset_id.clone()),
                        ..base_location
                    };
                    let Some(probe) = media.get(&source.asset_id) else {
                        report.unsupported.push(UnsupportedRenderItem {
                            location,
                            reason: UnsupportedRenderReason::MissingProbe,
                        });
                        continue;
                    };
                    if let Some(media_duration) = probe.duration {
                        let source_end = clip.source_in.seconds().checked_add(
                            ExactRational::from_integer(i128::from(clip.timeline_range.duration))
                                .checked_div(plan.frame_rate.as_rational())?
                                .checked_mul(clip.playback_rate)?,
                        )?;
                        if source_end.checked_cmp(media_duration.seconds())?
                            == std::cmp::Ordering::Greater
                        {
                            report.unsupported.push(UnsupportedRenderItem {
                                location: location.clone(),
                                reason: UnsupportedRenderReason::SourceRangeExceedsMedia {
                                    source_end: MediaTime::from_seconds(source_end),
                                    media_duration,
                                },
                            });
                        }
                    }
                    match track.kind {
                        TrackKind::Video => inspect_video(
                            probe,
                            source.stream_index,
                            source.frame_rate,
                            capabilities,
                            location,
                            report,
                        ),
                        TrackKind::Audio => inspect_audio(
                            probe,
                            source.stream_index,
                            capabilities,
                            location,
                            report,
                        ),
                    }
                }
            }
        }
    }
    Ok(())
}

fn inspect_video(
    probe: &MediaProbe,
    requested_stream: Option<usize>,
    planned_frame_rate: Option<FrameRate>,
    capabilities: &RendererCapabilities,
    location: PreflightLocation,
    report: &mut RenderPreflightReport,
) {
    let Some(video) = &probe.video else {
        report.unsupported.push(UnsupportedRenderItem {
            location: location.clone(),
            reason: UnsupportedRenderReason::MissingVideoStream,
        });
        return;
    };
    if requested_stream.is_some_and(|index| index != video.stream_index) {
        report.unsupported.push(UnsupportedRenderItem {
            location,
            reason: UnsupportedRenderReason::MissingVideoStream,
        });
        return;
    }
    if let (Some(planned), Some(probed)) = (planned_frame_rate, video.source_frame_rate)
        && planned != probed
    {
        report.unsupported.push(UnsupportedRenderItem {
            location: location.clone(),
            reason: UnsupportedRenderReason::SourceFrameRateMismatch { planned, probed },
        });
    }
    if video.width == 0 || video.height == 0 {
        report.unsupported.push(UnsupportedRenderItem {
            location: location.clone(),
            reason: UnsupportedRenderReason::VideoParametersUnavailable,
        });
    }
    if !capabilities
        .video_decoder_codec_ids
        .contains(&video.codec_id)
    {
        report.unsupported.push(UnsupportedRenderItem {
            location: location.clone(),
            reason: UnsupportedRenderReason::VideoDecoderUnavailable {
                codec_id: video.codec_id.clone(),
            },
        });
    }
    if video.width > capabilities.max_width || video.height > capabilities.max_height {
        report.unsupported.push(UnsupportedRenderItem {
            location: location.clone(),
            reason: UnsupportedRenderReason::DimensionsExceedLimit {
                width: video.width,
                height: video.height,
                max_width: capabilities.max_width,
                max_height: capabilities.max_height,
            },
        });
    }
    let rotation = orthogonal_rotation(video.display_rotation_degrees);
    if rotation.is_none_or(|rotation| !capabilities.display_rotations.contains(&rotation)) {
        report.unsupported.push(UnsupportedRenderItem {
            location: location.clone(),
            reason: UnsupportedRenderReason::DisplayRotationUnsupported {
                degrees: video.display_rotation_degrees.round() as i32,
            },
        });
    }
    if video.display_mirrored && !capabilities.supports_display_mirroring {
        report.unsupported.push(UnsupportedRenderItem {
            location,
            reason: UnsupportedRenderReason::DisplayMirroringUnsupported,
        });
    }
}

fn orthogonal_rotation(value: f64) -> Option<u16> {
    let normalized = value.rem_euclid(360.0);
    [0_u16, 90, 180, 270].into_iter().find(|candidate| {
        let difference = (normalized - f64::from(*candidate)).abs();
        difference.min(360.0 - difference) <= 0.01
    })
}

fn inspect_audio(
    probe: &MediaProbe,
    requested_stream: Option<usize>,
    capabilities: &RendererCapabilities,
    location: PreflightLocation,
    report: &mut RenderPreflightReport,
) {
    let audio = match requested_stream {
        Some(index) => probe
            .audio_streams
            .iter()
            .find(|stream| stream.stream_index == index),
        None => probe.audio_streams.first(),
    };
    let Some(audio) = audio else {
        report.unsupported.push(UnsupportedRenderItem {
            location,
            reason: UnsupportedRenderReason::MissingAudioStream,
        });
        return;
    };
    inspect_audio_codec(audio, capabilities, location, report);
}

fn inspect_audio_codec(
    audio: &AudioProbe,
    capabilities: &RendererCapabilities,
    location: PreflightLocation,
    report: &mut RenderPreflightReport,
) {
    if audio.sample_rate.is_none() || audio.channels.is_none() {
        report.unsupported.push(UnsupportedRenderItem {
            location: location.clone(),
            reason: UnsupportedRenderReason::AudioParametersUnavailable,
        });
    }
    if !capabilities
        .audio_decoder_codec_ids
        .contains(&audio.codec_id)
    {
        report.unsupported.push(UnsupportedRenderItem {
            location,
            reason: UnsupportedRenderReason::AudioDecoderUnavailable {
                codec_id: audio.codec_id.clone(),
            },
        });
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use crate::plan::{ClipPlan, Effect, MediaSource, TrackPlan};
    use crate::probe::{MediaKind, VideoProbe};
    use crate::time::{ExactRational, FrameRange, FrameRate, MediaTime};

    use super::*;

    #[test]
    fn preflight_reports_each_unsupported_capability() {
        let rate = FrameRate::new(24, 1).unwrap();
        let plan = CompositionPlan {
            id: "root".into(),
            frame_rate: rate,
            width: 1920,
            height: 1080,
            duration_frames: 24,
            tracks: vec![TrackPlan {
                id: "video".into(),
                kind: TrackKind::Video,
                clips: vec![ClipPlan {
                    id: "clip".into(),
                    timeline_range: FrameRange::new(0, 24).unwrap(),
                    source_in: MediaTime::ZERO,
                    playback_rate: ExactRational::ONE,
                    source: ClipSource::Media(MediaSource {
                        asset_id: "asset".into(),
                        path: PathBuf::from("clip.mov"),
                        kind: TrackKind::Video,
                        stream_index: Some(0),
                        frame_rate: Some(rate),
                    }),
                    effects: vec![Effect::Blur { radius: 8.0 }],
                }],
            }],
        };
        let media = HashMap::from([(
            "asset".into(),
            MediaProbe {
                path: PathBuf::from("clip.mov"),
                kind: MediaKind::Video,
                container: "mov".into(),
                duration: None,
                bit_rate: None,
                video: Some(VideoProbe {
                    stream_index: 0,
                    codec_id: "h264".into(),
                    decoder_name: Some("h264".into()),
                    width: 3840,
                    height: 2160,
                    display_width: 3840,
                    display_height: 2160,
                    display_rotation_degrees: 0.0,
                    display_mirrored: false,
                    source_frame_rate: Some(rate),
                    frame_count: Some(24),
                    pixel_format: Some("yuv420p".into()),
                }),
                audio_streams: Vec::new(),
            },
        )]);
        let capabilities = RendererCapabilities {
            supported_effects: BTreeSet::new(),
            video_decoder_codec_ids: BTreeSet::new(),
            audio_decoder_codec_ids: BTreeSet::new(),
            display_rotations: [0].into_iter().collect(),
            max_width: 1920,
            max_height: 1080,
            supports_nested_compositions: true,
            supports_display_mirroring: false,
        };

        let report = preflight_render(&plan, &capabilities, &media).unwrap();

        assert_eq!(report.unsupported.len(), 3);
        assert!(report.unsupported.iter().any(|item| matches!(
            item.reason,
            UnsupportedRenderReason::EffectUnsupported {
                effect: EffectKind::Blur
            }
        )));
        assert!(report.require_supported().is_err());
    }
}
