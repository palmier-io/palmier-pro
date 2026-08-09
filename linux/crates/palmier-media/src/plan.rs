use std::cmp::Ordering;
use std::collections::HashSet;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::error::{MediaError, Result};
use crate::time::{ExactRational, FrameRange, FrameRate, MediaTime};

const MAX_NESTING_DEPTH: usize = 32;

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrackKind {
    Video,
    Audio,
}

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EffectKind {
    Opacity,
    Transform,
    Crop,
    ColorAdjustment,
    Lut,
    ChromaKey,
    Blur,
    Stabilization,
    Volume,
    Pan,
    Equalizer,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Effect {
    Opacity {
        value: f32,
    },
    Transform {
        x: f32,
        y: f32,
        scale_x: f32,
        scale_y: f32,
        rotation_degrees: f32,
    },
    Crop {
        left: f32,
        top: f32,
        right: f32,
        bottom: f32,
    },
    ColorAdjustment {
        exposure: f32,
        contrast: f32,
        saturation: f32,
    },
    Lut {
        identifier: String,
    },
    ChromaKey {
        color_rgba: [u8; 4],
        tolerance: f32,
    },
    Blur {
        radius: f32,
    },
    Stabilization,
    Volume {
        gain: f32,
    },
    Pan {
        value: f32,
    },
    Equalizer {
        bands: Vec<f32>,
    },
}

impl Effect {
    pub const fn kind(&self) -> EffectKind {
        match self {
            Self::Opacity { .. } => EffectKind::Opacity,
            Self::Transform { .. } => EffectKind::Transform,
            Self::Crop { .. } => EffectKind::Crop,
            Self::ColorAdjustment { .. } => EffectKind::ColorAdjustment,
            Self::Lut { .. } => EffectKind::Lut,
            Self::ChromaKey { .. } => EffectKind::ChromaKey,
            Self::Blur { .. } => EffectKind::Blur,
            Self::Stabilization => EffectKind::Stabilization,
            Self::Volume { .. } => EffectKind::Volume,
            Self::Pan { .. } => EffectKind::Pan,
            Self::Equalizer { .. } => EffectKind::Equalizer,
        }
    }

    fn validate_for_track(&self, track_kind: TrackKind) -> Result<()> {
        let value_is_finite = match self {
            Self::Opacity { value } => value.is_finite(),
            Self::Transform {
                x,
                y,
                scale_x,
                scale_y,
                rotation_degrees,
            } => [x, y, scale_x, scale_y, rotation_degrees]
                .into_iter()
                .all(|value| value.is_finite()),
            Self::Crop {
                left,
                top,
                right,
                bottom,
            } => [left, top, right, bottom]
                .into_iter()
                .all(|value| value.is_finite()),
            Self::ColorAdjustment {
                exposure,
                contrast,
                saturation,
            } => [exposure, contrast, saturation]
                .into_iter()
                .all(|value| value.is_finite()),
            Self::Lut { identifier } => !identifier.trim().is_empty(),
            Self::ChromaKey { tolerance, .. } | Self::Blur { radius: tolerance } => {
                tolerance.is_finite() && *tolerance >= 0.0
            }
            Self::Stabilization => true,
            Self::Volume { gain } | Self::Pan { value: gain } => gain.is_finite(),
            Self::Equalizer { bands } => {
                !bands.is_empty() && bands.iter().all(|value| value.is_finite())
            }
        };
        if !value_is_finite {
            return Err(MediaError::InvalidPlan(format!(
                "effect {:?} has invalid values",
                self.kind()
            )));
        }

        let is_video = matches!(
            self.kind(),
            EffectKind::Opacity
                | EffectKind::Transform
                | EffectKind::Crop
                | EffectKind::ColorAdjustment
                | EffectKind::Lut
                | EffectKind::ChromaKey
                | EffectKind::Blur
                | EffectKind::Stabilization
        );
        if (track_kind == TrackKind::Video) != is_video {
            return Err(MediaError::InvalidPlan(format!(
                "effect {:?} does not belong on a {:?} track",
                self.kind(),
                track_kind
            )));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MediaSource {
    pub asset_id: String,
    pub path: PathBuf,
    pub kind: TrackKind,
    pub stream_index: Option<usize>,
    pub frame_rate: Option<FrameRate>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClipSource {
    Media(MediaSource),
    Nested { plan: Box<CompositionPlan> },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ClipPlan {
    pub id: String,
    pub timeline_range: FrameRange,
    pub source_in: MediaTime,
    pub playback_rate: ExactRational,
    pub source: ClipSource,
    #[serde(default)]
    pub effects: Vec<Effect>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TrackPlan {
    pub id: String,
    pub kind: TrackKind,
    #[serde(default)]
    pub clips: Vec<ClipPlan>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CompositionPlan {
    pub id: String,
    pub frame_rate: FrameRate,
    pub width: u32,
    pub height: u32,
    pub duration_frames: u64,
    #[serde(default)]
    pub tracks: Vec<TrackPlan>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SourceFrameMapping {
    pub root_track_id: String,
    pub track_path: Vec<String>,
    pub clip_path: Vec<String>,
    pub asset_id: String,
    pub path: PathBuf,
    pub stream_index: Option<usize>,
    pub source_time: MediaTime,
    pub source_frame: Option<ExactRational>,
}

#[derive(Clone, Copy)]
pub struct CompositionMapper<'a> {
    plan: &'a CompositionPlan,
}

impl CompositionPlan {
    pub fn validate(&self) -> Result<()> {
        self.validate_at_depth(0)
    }

    /// Maps an output frame's start instant to exact source positions.
    pub fn map_frame(&self, frame: u64) -> Result<Vec<SourceFrameMapping>> {
        self.mapper()?.map_frame(frame)
    }

    pub fn mapper(&self) -> Result<CompositionMapper<'_>> {
        self.validate()?;
        Ok(CompositionMapper { plan: self })
    }

    fn map_validated_frame(&self, frame: u64) -> Result<Vec<SourceFrameMapping>> {
        if frame >= self.duration_frames {
            return Err(MediaError::InvalidRequest(format!(
                "frame {frame} is outside composition {}",
                self.id
            )));
        }
        self.map_position(
            ExactRational::from_integer(i128::from(frame)),
            None,
            &mut Vec::new(),
            &mut Vec::new(),
            None,
        )
    }

    fn map_position(
        &self,
        position: ExactRational,
        kind_filter: Option<TrackKind>,
        track_path: &mut Vec<String>,
        clip_path: &mut Vec<String>,
        root_track_id: Option<&str>,
    ) -> Result<Vec<SourceFrameMapping>> {
        let mut mappings = Vec::new();
        for track in &self.tracks {
            if kind_filter.is_some_and(|kind| kind != track.kind) {
                continue;
            }
            track_path.push(track.id.clone());
            for clip in &track.clips {
                if !clip.timeline_range.contains_position(position)? {
                    continue;
                }
                clip_path.push(clip.id.clone());
                let local_frame = position.checked_sub(ExactRational::from_integer(i128::from(
                    clip.timeline_range.start,
                )))?;
                let source_seconds = clip.source_in.seconds().checked_add(
                    local_frame
                        .checked_div(self.frame_rate.as_rational())?
                        .checked_mul(clip.playback_rate)?,
                )?;
                let root_track = root_track_id.unwrap_or(&track.id);

                match &clip.source {
                    ClipSource::Media(source) => {
                        let source_frame = source
                            .frame_rate
                            .map(|rate| source_seconds.checked_mul(rate.as_rational()))
                            .transpose()?;
                        mappings.push(SourceFrameMapping {
                            root_track_id: root_track.to_owned(),
                            track_path: track_path.clone(),
                            clip_path: clip_path.clone(),
                            asset_id: source.asset_id.clone(),
                            path: source.path.clone(),
                            stream_index: source.stream_index,
                            source_time: MediaTime::from_seconds(source_seconds),
                            source_frame,
                        });
                    }
                    ClipSource::Nested { plan } => {
                        let nested_position =
                            source_seconds.checked_mul(plan.frame_rate.as_rational())?;
                        mappings.extend(plan.map_position(
                            nested_position,
                            Some(track.kind),
                            track_path,
                            clip_path,
                            Some(root_track),
                        )?);
                    }
                }
                clip_path.pop();
            }
            track_path.pop();
        }
        Ok(mappings)
    }

    fn validate_at_depth(&self, depth: usize) -> Result<()> {
        if depth > MAX_NESTING_DEPTH {
            return Err(MediaError::InvalidPlan(format!(
                "composition {} exceeds the nesting limit",
                self.id
            )));
        }
        if self.id.trim().is_empty() {
            return Err(MediaError::InvalidPlan(
                "composition id cannot be empty".into(),
            ));
        }
        if self.width == 0 || self.height == 0 {
            return Err(MediaError::InvalidPlan(format!(
                "composition {} has zero dimensions",
                self.id
            )));
        }
        if self.duration_frames == 0 {
            return Err(MediaError::InvalidPlan(format!(
                "composition {} has zero duration",
                self.id
            )));
        }

        let mut track_ids = HashSet::new();
        let mut clip_ids = HashSet::new();
        for track in &self.tracks {
            if track.id.trim().is_empty() || !track_ids.insert(&track.id) {
                return Err(MediaError::InvalidPlan(format!(
                    "composition {} has an empty or duplicate track id",
                    self.id
                )));
            }
            let mut ranges = Vec::with_capacity(track.clips.len());
            for clip in &track.clips {
                if clip.id.trim().is_empty() || !clip_ids.insert(&clip.id) {
                    return Err(MediaError::InvalidPlan(format!(
                        "composition {} has an empty or duplicate clip id",
                        self.id
                    )));
                }
                if clip.timeline_range.duration == 0
                    || clip.timeline_range.end()? > self.duration_frames
                {
                    return Err(MediaError::InvalidPlan(format!(
                        "clip {} is outside composition {}",
                        clip.id, self.id
                    )));
                }
                if clip.source_in.seconds().is_negative() || !clip.playback_rate.is_positive() {
                    return Err(MediaError::InvalidPlan(format!(
                        "clip {} has invalid source timing",
                        clip.id
                    )));
                }
                for effect in &clip.effects {
                    effect.validate_for_track(track.kind)?;
                }

                match &clip.source {
                    ClipSource::Media(source) => {
                        if source.asset_id.trim().is_empty() || source.path.as_os_str().is_empty() {
                            return Err(MediaError::InvalidPlan(format!(
                                "clip {} has an invalid media source",
                                clip.id
                            )));
                        }
                        if source.kind != track.kind {
                            return Err(MediaError::InvalidPlan(format!(
                                "clip {} source type does not match track {}",
                                clip.id, track.id
                            )));
                        }
                    }
                    ClipSource::Nested { plan } => {
                        plan.validate_at_depth(depth + 1)?;
                        let source_end = clip.source_in.seconds().checked_add(
                            ExactRational::from_integer(i128::from(clip.timeline_range.duration))
                                .checked_div(self.frame_rate.as_rational())?
                                .checked_mul(clip.playback_rate)?,
                        )?;
                        let nested_end =
                            ExactRational::from_integer(i128::from(plan.duration_frames))
                                .checked_div(plan.frame_rate.as_rational())?;
                        if source_end.checked_cmp(nested_end)? == Ordering::Greater {
                            return Err(MediaError::InvalidPlan(format!(
                                "clip {} reads past nested composition {}",
                                clip.id, plan.id
                            )));
                        }
                    }
                }
                ranges.push((
                    clip.timeline_range.start,
                    clip.timeline_range.end()?,
                    &clip.id,
                ));
            }

            ranges.sort_unstable_by_key(|range| range.0);
            for pair in ranges.windows(2) {
                if pair[0].1 > pair[1].0 {
                    return Err(MediaError::InvalidPlan(format!(
                        "clips {} and {} overlap on track {}",
                        pair[0].2, pair[1].2, track.id
                    )));
                }
            }
        }
        Ok(())
    }
}

impl<'a> CompositionMapper<'a> {
    pub fn map_frame(&self, frame: u64) -> Result<Vec<SourceFrameMapping>> {
        self.plan.map_validated_frame(frame)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn media_clip(
        id: &str,
        start: u64,
        duration: u64,
        source_in_frames: i128,
        rate: FrameRate,
    ) -> ClipPlan {
        ClipPlan {
            id: id.into(),
            timeline_range: FrameRange::new(start, duration).unwrap(),
            source_in: MediaTime::from_seconds(
                ExactRational::from_integer(source_in_frames)
                    .checked_div(rate.as_rational())
                    .unwrap(),
            ),
            playback_rate: ExactRational::ONE,
            source: ClipSource::Media(MediaSource {
                asset_id: format!("asset-{id}"),
                path: PathBuf::from(format!("{id}.mov")),
                kind: TrackKind::Video,
                stream_index: Some(0),
                frame_rate: Some(rate),
            }),
            effects: Vec::new(),
        }
    }

    fn plan(id: &str, rate: FrameRate, duration: u64, clips: Vec<ClipPlan>) -> CompositionPlan {
        CompositionPlan {
            id: id.into(),
            frame_rate: rate,
            width: 1920,
            height: 1080,
            duration_frames: duration,
            tracks: vec![TrackPlan {
                id: format!("track-{id}"),
                kind: TrackKind::Video,
                clips,
            }],
        }
    }

    #[test]
    fn maps_mixed_frame_rates_without_rounding() {
        let timeline_rate = FrameRate::new(24_000, 1_001).unwrap();
        let source_rate = FrameRate::new(30_000, 1_001).unwrap();
        let composition = plan(
            "root",
            timeline_rate,
            100,
            vec![media_clip("clip", 0, 100, 10, source_rate)],
        );

        let mapping = composition.map_frame(12).unwrap().remove(0);

        assert_eq!(mapping.source_frame, Some(ExactRational::from_integer(25)));
    }

    #[test]
    fn maps_nested_clip_through_both_time_bases() {
        let nested_rate = FrameRate::new(30, 1).unwrap();
        let nested = plan(
            "nested",
            nested_rate,
            300,
            vec![media_clip("leaf", 0, 300, 0, nested_rate)],
        );
        let root = CompositionPlan {
            id: "root".into(),
            frame_rate: FrameRate::new(24, 1).unwrap(),
            width: 1920,
            height: 1080,
            duration_frames: 120,
            tracks: vec![TrackPlan {
                id: "root-track".into(),
                kind: TrackKind::Video,
                clips: vec![ClipPlan {
                    id: "carrier".into(),
                    timeline_range: FrameRange::new(0, 120).unwrap(),
                    source_in: MediaTime::ZERO,
                    playback_rate: ExactRational::new(1, 2).unwrap(),
                    source: ClipSource::Nested {
                        plan: Box::new(nested),
                    },
                    effects: Vec::new(),
                }],
            }],
        };

        let mapping = root.map_frame(48).unwrap().remove(0);

        assert_eq!(mapping.source_frame, Some(ExactRational::from_integer(30)));
        assert_eq!(mapping.clip_path, ["carrier", "leaf"]);
    }

    #[test]
    fn mapping_uses_half_open_clip_ranges() {
        let rate = FrameRate::new(24, 1).unwrap();
        let composition = plan(
            "root",
            rate,
            20,
            vec![
                media_clip("first", 0, 10, 0, rate),
                media_clip("second", 10, 10, 0, rate),
            ],
        );

        assert_eq!(composition.map_frame(9).unwrap()[0].asset_id, "asset-first");
        assert_eq!(
            composition.map_frame(10).unwrap()[0].asset_id,
            "asset-second"
        );
    }

    #[test]
    fn validation_rejects_overlapping_clips() {
        let rate = FrameRate::new(24, 1).unwrap();
        let composition = plan(
            "root",
            rate,
            20,
            vec![
                media_clip("first", 0, 11, 0, rate),
                media_clip("second", 10, 10, 0, rate),
            ],
        );

        assert!(matches!(
            composition.validate(),
            Err(MediaError::InvalidPlan(message)) if message.contains("overlap")
        ));
    }
}
