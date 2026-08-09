use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::frames::{Frame, FrameError, FrameRange, swift_round};
use crate::models::{AnimPair, Clip, Keyframe, KeyframeInterpolatable, KeyframeTrack, new_id};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "camelCase")]
pub enum OverwriteAction {
    Remove {
        clip_id: String,
    },
    TrimEnd {
        clip_id: String,
        new_duration: Frame,
    },
    TrimStart {
        clip_id: String,
        new_start_frame: Frame,
        new_trim_start: Frame,
        new_duration: Frame,
    },
    Split {
        clip_id: String,
        left_duration: Frame,
        right_id: String,
        right_start_frame: Frame,
        right_trim_start: Frame,
        right_duration: Frame,
    },
}

pub struct OverwriteEngine;

impl OverwriteEngine {
    pub fn compute(clips: &[Clip], region_start: Frame, region_end: Frame) -> Vec<OverwriteAction> {
        if region_end <= region_start {
            return Vec::new();
        }
        let mut actions = Vec::new();
        for clip in clips {
            let clip_start = clip.start_frame;
            let clip_end = clip.end_frame();
            if clip_end <= region_start || clip_start >= region_end {
                continue;
            }
            if clip_start >= region_start && clip_end <= region_end {
                actions.push(OverwriteAction::Remove {
                    clip_id: clip.id.clone(),
                });
            } else if clip_start < region_start && clip_end > region_end {
                let right_trim_start = swift_round((region_end - clip_start) as f64 * clip.speed)
                    .unwrap_or_default()
                    + clip.trim_start_frame;
                actions.push(OverwriteAction::Split {
                    clip_id: clip.id.clone(),
                    left_duration: region_start - clip_start,
                    right_id: new_id(),
                    right_start_frame: region_end,
                    right_trim_start,
                    right_duration: clip_end - region_end,
                });
            } else if clip_start < region_start {
                actions.push(OverwriteAction::TrimEnd {
                    clip_id: clip.id.clone(),
                    new_duration: region_start - clip_start,
                });
            } else {
                let trim_amount = region_end - clip_start;
                let new_trim_start = swift_round(trim_amount as f64 * clip.speed)
                    .unwrap_or_default()
                    + clip.trim_start_frame;
                actions.push(OverwriteAction::TrimStart {
                    clip_id: clip.id.clone(),
                    new_start_frame: region_end,
                    new_trim_start,
                    new_duration: clip_end - region_end,
                });
            }
        }
        actions
    }

    pub fn clear_region(
        clips: &mut Vec<Clip>,
        range: FrameRange,
        excluding: &[String],
    ) -> Result<OverwriteReport, SplitError> {
        let actions = Self::compute(
            &clips
                .iter()
                .filter(|clip| !excluding.contains(&clip.id))
                .cloned()
                .collect::<Vec<_>>(),
            range.start,
            range.end,
        );
        let mut report = OverwriteReport::default();
        for action in actions {
            match action {
                OverwriteAction::Remove { clip_id } => {
                    let before = clips.len();
                    clips.retain(|clip| clip.id != clip_id);
                    if before != clips.len() {
                        report.removed_clip_ids.push(clip_id);
                    }
                }
                OverwriteAction::TrimEnd {
                    clip_id,
                    new_duration,
                } => {
                    if let Some(clip) = clips.iter_mut().find(|clip| clip.id == clip_id) {
                        let source_delta =
                            swift_round((clip.duration_frames - new_duration) as f64 * clip.speed)?;
                        clip.trim_end_frame += source_delta;
                        clip.set_duration(new_duration);
                        report.updated_clip_ids.push(clip_id);
                    }
                }
                OverwriteAction::TrimStart {
                    clip_id,
                    new_start_frame,
                    new_trim_start,
                    new_duration,
                } => {
                    if let Some(clip) = clips.iter_mut().find(|clip| clip.id == clip_id) {
                        clip.start_frame = new_start_frame;
                        clip.trim_start_frame = new_trim_start;
                        clip.set_duration(new_duration);
                        report.updated_clip_ids.push(clip_id);
                    }
                }
                OverwriteAction::Split {
                    clip_id, right_id, ..
                } => {
                    let Some(index) = clips.iter().position(|clip| clip.id == clip_id) else {
                        continue;
                    };
                    let original = clips.remove(index);
                    let (left, middle_and_tail) =
                        split_clip_value(&original, range.start, right_id)?;
                    let (_, tail) = split_clip_value(&middle_and_tail, range.end, new_id())?;
                    report.updated_clip_ids.push(left.id.clone());
                    report.created_clip_ids.push(tail.id.clone());
                    clips.push(left);
                    clips.push(tail);
                }
            }
        }
        clips.sort_by_key(|clip| clip.start_frame);
        Ok(report)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OverwriteReport {
    pub created_clip_ids: Vec<String>,
    pub removed_clip_ids: Vec<String>,
    pub updated_clip_ids: Vec<String>,
}

#[derive(Debug, Error)]
pub enum SplitError {
    #[error("the split frame must be strictly inside the clip")]
    OutsideClip,
    #[error(transparent)]
    Frame(#[from] FrameError),
}

pub fn split_clip_value(
    clip: &Clip,
    at_frame: Frame,
    right_id: String,
) -> Result<(Clip, Clip), SplitError> {
    if at_frame <= clip.start_frame || at_frame >= clip.end_frame() {
        return Err(SplitError::OutsideClip);
    }
    let split_offset = at_frame - clip.start_frame;
    let left_source = swift_round(split_offset as f64 * clip.speed)?;
    let right_source = swift_round((clip.duration_frames - split_offset) as f64 * clip.speed)?;

    let mut left = clip.clone();
    left.duration_frames = split_offset;
    left.trim_end_frame += right_source;
    left.fade_out_frames = 0;

    let mut right = clip.clone();
    right.id = right_id;
    right.start_frame = at_frame;
    right.duration_frames = clip.duration_frames - split_offset;
    right.trim_start_frame += left_source;
    right.fade_in_frames = 0;

    (left.opacity_track, right.opacity_track) =
        split_track(clip.opacity_track.as_ref(), split_offset, clip.opacity);
    (left.volume_track, right.volume_track) =
        split_track(clip.volume_track.as_ref(), split_offset, clip.volume);
    (left.position_track, right.position_track) = split_track(
        clip.position_track.as_ref(),
        split_offset,
        AnimPair::default(),
    );
    (left.scale_track, right.scale_track) = split_track(
        clip.scale_track.as_ref(),
        split_offset,
        AnimPair { a: 1.0, b: 1.0 },
    );
    (left.rotation_track, right.rotation_track) =
        split_track(clip.rotation_track.as_ref(), split_offset, 0.0);
    (left.crop_track, right.crop_track) =
        split_track(clip.crop_track.as_ref(), split_offset, clip.crop);
    left.clamp_fades_to_duration();
    right.clamp_fades_to_duration();
    Ok((left, right))
}

fn split_track<T>(
    track: Option<&KeyframeTrack<T>>,
    split_offset: Frame,
    fallback: T,
) -> (Option<KeyframeTrack<T>>, Option<KeyframeTrack<T>>)
where
    T: KeyframeInterpolatable + Clone + PartialEq,
{
    let Some(track) = track.filter(|track| track.is_active()) else {
        return (track.cloned(), track.cloned());
    };
    let boundary = track.sample(split_offset, fallback.clone());
    let mut left_keyframes: Vec<_> = track
        .keyframes
        .iter()
        .filter(|keyframe| keyframe.frame <= split_offset)
        .cloned()
        .collect();
    if left_keyframes.last().map(|keyframe| keyframe.frame) != Some(split_offset) {
        left_keyframes.push(Keyframe::new(split_offset, boundary));
    }
    (
        Some(KeyframeTrack {
            keyframes: left_keyframes,
        }),
        track.rebased(split_offset, fallback),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{Interpolation, Keyframe};

    fn clip(id: &str, start: Frame, duration: Frame) -> Clip {
        let mut clip = Clip::new("media", start, duration);
        clip.id = id.to_owned();
        clip
    }

    #[test]
    fn overwrite_covers_all_half_open_overlap_branches() {
        let inside = clip("inside", 60, 30);
        let left = clip("left", 0, 60);
        let right = clip("right", 100, 200);
        let actions = OverwriteEngine::compute(&[inside, left, right], 50, 150);
        assert_eq!(actions.len(), 3);
        assert!(matches!(actions[0], OverwriteAction::Remove { .. }));
        assert!(matches!(actions[1], OverwriteAction::TrimEnd { .. }));
        assert!(matches!(actions[2], OverwriteAction::TrimStart { .. }));
        assert!(OverwriteEngine::compute(&[clip("adjacent", 150, 10)], 50, 150).is_empty());
    }

    #[test]
    fn overwrite_split_respects_speed_and_trim() {
        let mut value = clip("clip", 0, 200);
        value.speed = 2.0;
        value.trim_start_frame = 10;
        let actions = OverwriteEngine::compute(&[value], 50, 150);
        assert!(matches!(
            &actions[0],
            OverwriteAction::Split {
                left_duration: 50,
                right_start_frame: 150,
                right_trim_start: 310,
                right_duration: 50,
                ..
            }
        ));
    }

    #[test]
    fn split_preserves_keyframe_continuity_and_fades() {
        let mut value = clip("clip", 0, 60);
        value.fade_in_frames = 15;
        value.fade_out_frames = 20;
        value.opacity_track = Some(KeyframeTrack {
            keyframes: vec![
                Keyframe {
                    frame: 0,
                    value: 1.0,
                    interpolation_out: Interpolation::Hold,
                },
                Keyframe::new(30, 0.5),
            ],
        });
        let (left, right) = split_clip_value(&value, 10, "right".to_owned()).unwrap();
        assert_eq!(left.fade_in_frames, 10);
        assert_eq!(left.fade_out_frames, 0);
        assert_eq!(right.fade_in_frames, 0);
        assert_eq!(right.fade_out_frames, 20);
        assert_eq!(right.opacity_track.unwrap().sample(5, 0.0), 1.0);
    }

    #[test]
    fn clear_region_removes_middle_and_keeps_both_sides() {
        let mut clips = vec![clip("clip", 0, 100)];
        let report =
            OverwriteEngine::clear_region(&mut clips, FrameRange { start: 40, end: 50 }, &[])
                .unwrap();
        assert_eq!(
            clips
                .iter()
                .map(|clip| (clip.start_frame, clip.end_frame()))
                .collect::<Vec<_>>(),
            vec![(0, 40), (50, 100)]
        );
        assert_eq!(report.created_clip_ids.len(), 1);
    }
}
