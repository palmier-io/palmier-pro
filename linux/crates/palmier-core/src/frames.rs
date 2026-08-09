use serde::{Deserialize, Serialize};
use thiserror::Error;

pub type Frame = i64;

#[derive(Debug, Clone, PartialEq, Eq, Error, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FrameError {
    #[error("the value must be finite")]
    NonFinite,
    #[error("the frame value is outside the supported range")]
    OutOfRange,
    #[error("fps must be greater than zero")]
    InvalidFps,
    #[error("frame arithmetic overflowed")]
    Overflow,
    #[error("the frame range must be half-open with end greater than start")]
    InvalidRange,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FrameRange {
    pub start: Frame,
    pub end: Frame,
}

impl FrameRange {
    pub fn new(start: Frame, end: Frame) -> Result<Self, FrameError> {
        if end <= start {
            return Err(FrameError::InvalidRange);
        }
        Ok(Self { start, end })
    }

    pub fn length(self) -> Frame {
        self.end - self.start
    }

    pub fn contains(self, frame: Frame) -> bool {
        frame >= self.start && frame < self.end
    }

    pub fn overlaps(self, other: Self) -> bool {
        self.start < other.end && other.start < self.end
    }

    pub fn touches_or_overlaps(self, other: Self) -> bool {
        self.start <= other.end && other.start <= self.end
    }
}

pub fn checked_add(left: Frame, right: Frame) -> Result<Frame, FrameError> {
    left.checked_add(right).ok_or(FrameError::Overflow)
}

pub fn checked_sub(left: Frame, right: Frame) -> Result<Frame, FrameError> {
    left.checked_sub(right).ok_or(FrameError::Overflow)
}

/// Swift's default `rounded()` rule: nearest, with ties away from zero.
pub fn swift_round(value: f64) -> Result<Frame, FrameError> {
    if !value.is_finite() {
        return Err(FrameError::NonFinite);
    }
    let rounded = value.round();
    if rounded < Frame::MIN as f64 || rounded > Frame::MAX as f64 {
        return Err(FrameError::OutOfRange);
    }
    Ok(rounded as Frame)
}

/// Matches `Int(seconds * Double(fps))`, including truncation toward zero.
pub fn seconds_to_frame(seconds: f64, fps: i32) -> Result<Frame, FrameError> {
    if fps <= 0 {
        return Err(FrameError::InvalidFps);
    }
    if !seconds.is_finite() {
        return Err(FrameError::NonFinite);
    }
    let value = seconds * f64::from(fps);
    if !value.is_finite() || value < Frame::MIN as f64 || value > Frame::MAX as f64 {
        return Err(FrameError::OutOfRange);
    }
    Ok(value.trunc() as Frame)
}

pub fn frame_to_seconds(frame: Frame, fps: i32) -> Result<f64, FrameError> {
    if fps <= 0 {
        return Err(FrameError::InvalidFps);
    }
    Ok(frame as f64 / f64::from(fps))
}

pub fn merge_ranges(ranges: impl IntoIterator<Item = FrameRange>) -> Vec<FrameRange> {
    let mut ranges: Vec<_> = ranges
        .into_iter()
        .filter(|range| range.end > range.start)
        .collect();
    ranges.sort_by_key(|range| (range.start, range.end));

    let mut merged: Vec<FrameRange> = Vec::new();
    for range in ranges {
        if let Some(last) = merged.last_mut()
            && range.start <= last.end
        {
            last.end = last.end.max(range.end);
            continue;
        }
        merged.push(range);
    }
    merged
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn half_open_ranges_exclude_the_end() {
        let range = FrameRange::new(10, 20).unwrap();
        assert!(range.contains(10));
        assert!(range.contains(19));
        assert!(!range.contains(20));
        assert!(!range.overlaps(FrameRange::new(20, 30).unwrap()));
    }

    #[test]
    fn swift_rounding_moves_ties_away_from_zero() {
        assert_eq!(swift_round(2.5), Ok(3));
        assert_eq!(swift_round(-2.5), Ok(-3));
        assert_eq!(swift_round(24.75), Ok(25));
    }

    #[test]
    fn seconds_conversion_truncates_like_swift_int() {
        assert_eq!(seconds_to_frame(1.99, 30), Ok(59));
        assert_eq!(seconds_to_frame(-1.99, 30), Ok(-59));
        assert_eq!(frame_to_seconds(45, 30), Ok(1.5));
    }

    #[test]
    fn merge_ranges_combines_overlapping_and_touching_ranges() {
        let merged = merge_ranges([
            FrameRange {
                start: 50,
                end: 100,
            },
            FrameRange { start: 0, end: 25 },
            FrameRange { start: 20, end: 50 },
        ]);
        assert_eq!(merged, vec![FrameRange { start: 0, end: 100 }]);
    }
}
