use std::collections::HashSet;

use serde::{Deserialize, Serialize};

use crate::frames::{Frame, FrameRange, merge_ranges};
use crate::models::Clip;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipShift {
    pub clip_id: String,
    pub new_start_frame: Frame,
}

pub struct RippleEngine;

impl RippleEngine {
    pub fn shifts_after_removing(clips: &[Clip], removed_ids: &HashSet<String>) -> Vec<ClipShift> {
        let removed_ranges = clips
            .iter()
            .filter(|clip| removed_ids.contains(&clip.id))
            .map(|clip| FrameRange {
                start: clip.start_frame,
                end: clip.end_frame(),
            })
            .collect::<Vec<_>>();
        let remaining = clips
            .iter()
            .filter(|clip| !removed_ids.contains(&clip.id))
            .cloned()
            .collect::<Vec<_>>();
        Self::shifts_for_ranges(&remaining, &removed_ranges)
    }

    pub fn shifts_for_ranges(clips: &[Clip], removed_ranges: &[FrameRange]) -> Vec<ClipShift> {
        let merged = merge_ranges(removed_ranges.iter().copied());
        if merged.is_empty() {
            return Vec::new();
        }
        let mut clips = clips.iter().collect::<Vec<_>>();
        clips.sort_by_key(|clip| clip.start_frame);
        clips
            .into_iter()
            .filter_map(|clip| {
                let shift: Frame = merged
                    .iter()
                    .filter(|range| range.end <= clip.start_frame)
                    .map(|range| range.length())
                    .sum();
                (shift > 0).then(|| ClipShift {
                    clip_id: clip.id.clone(),
                    new_start_frame: clip.start_frame - shift,
                })
            })
            .collect()
    }

    pub fn push(
        clips: &[Clip],
        insert_frame: Frame,
        push_amount: Frame,
        exclude_ids: &HashSet<String>,
    ) -> Vec<ClipShift> {
        clips
            .iter()
            .filter(|clip| !exclude_ids.contains(&clip.id) && clip.start_frame >= insert_frame)
            .map(|clip| ClipShift {
                clip_id: clip.id.clone(),
                new_start_frame: clip.start_frame.saturating_add(push_amount),
            })
            .collect()
    }

    pub fn merge_ranges(ranges: &[FrameRange]) -> Vec<FrameRange> {
        merge_ranges(ranges.iter().copied())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clip(id: &str, start: Frame, duration: Frame) -> Clip {
        let mut clip = Clip::new("media", start, duration);
        clip.id = id.to_owned();
        clip
    }

    #[test]
    fn removing_multiple_ranges_shifts_by_merged_total() {
        let clips = vec![
            clip("r1", 0, 50),
            clip("r2", 100, 50),
            clip("tail", 200, 50),
        ];
        let removed = HashSet::from(["r1".to_owned(), "r2".to_owned()]);
        assert_eq!(
            RippleEngine::shifts_after_removing(&clips, &removed),
            vec![ClipShift {
                clip_id: "tail".to_owned(),
                new_start_frame: 100,
            }]
        );
    }

    #[test]
    fn touching_ranges_merge_before_shifting() {
        assert_eq!(
            RippleEngine::shifts_for_ranges(
                &[clip("tail", 200, 50)],
                &[
                    FrameRange { start: 0, end: 50 },
                    FrameRange {
                        start: 50,
                        end: 100
                    },
                ],
            ),
            vec![ClipShift {
                clip_id: "tail".to_owned(),
                new_start_frame: 100,
            }]
        );
    }

    #[test]
    fn a_range_must_end_at_or_before_the_clip_start() {
        let value = clip("clip", 100, 50);
        assert_eq!(
            RippleEngine::shifts_for_ranges(
                std::slice::from_ref(&value),
                &[FrameRange { start: 0, end: 100 }],
            )[0]
            .new_start_frame,
            0
        );
        assert!(
            RippleEngine::shifts_for_ranges(&[value], &[FrameRange { start: 0, end: 101 }],)
                .is_empty()
        );
    }

    #[test]
    fn push_moves_clips_at_and_after_the_insert() {
        let shifts = RippleEngine::push(
            &[clip("before", 0, 50), clip("at", 100, 50)],
            100,
            30,
            &HashSet::new(),
        );
        assert_eq!(
            shifts,
            vec![ClipShift {
                clip_id: "at".to_owned(),
                new_start_frame: 130,
            }]
        );
    }
}
