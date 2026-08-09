use std::cmp::Ordering;
use std::fmt;

use serde::{Deserialize, Serialize};

use crate::error::{MediaError, Result};

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "RationalRepr", into = "RationalRepr")]
pub struct ExactRational {
    numerator: i128,
    denominator: i128,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
struct RationalRepr {
    numerator: i128,
    denominator: i128,
}

impl ExactRational {
    pub const ZERO: Self = Self {
        numerator: 0,
        denominator: 1,
    };

    pub const ONE: Self = Self {
        numerator: 1,
        denominator: 1,
    };

    pub fn new(numerator: i128, denominator: i128) -> Result<Self> {
        if denominator == 0 {
            return Err(MediaError::InvalidRequest(
                "a rational denominator cannot be zero".into(),
            ));
        }

        let (numerator, denominator) = if denominator < 0 {
            (
                numerator
                    .checked_neg()
                    .ok_or(MediaError::ArithmeticOverflow("rational sign"))?,
                denominator
                    .checked_neg()
                    .ok_or(MediaError::ArithmeticOverflow("rational sign"))?,
            )
        } else {
            (numerator, denominator)
        };

        if numerator == 0 {
            return Ok(Self::ZERO);
        }

        let divisor = gcd(numerator.unsigned_abs(), denominator as u128) as i128;
        Ok(Self {
            numerator: numerator / divisor,
            denominator: denominator / divisor,
        })
    }

    pub const fn from_integer(value: i128) -> Self {
        Self {
            numerator: value,
            denominator: 1,
        }
    }

    pub const fn numerator(self) -> i128 {
        self.numerator
    }

    pub const fn denominator(self) -> i128 {
        self.denominator
    }

    pub fn is_negative(self) -> bool {
        self.numerator < 0
    }

    pub fn is_positive(self) -> bool {
        self.numerator > 0
    }

    pub fn checked_add(self, other: Self) -> Result<Self> {
        let left = self
            .numerator
            .checked_mul(other.denominator)
            .ok_or(MediaError::ArithmeticOverflow("rational addition"))?;
        let right = other
            .numerator
            .checked_mul(self.denominator)
            .ok_or(MediaError::ArithmeticOverflow("rational addition"))?;
        let numerator = left
            .checked_add(right)
            .ok_or(MediaError::ArithmeticOverflow("rational addition"))?;
        let denominator = self
            .denominator
            .checked_mul(other.denominator)
            .ok_or(MediaError::ArithmeticOverflow("rational addition"))?;
        Self::new(numerator, denominator)
    }

    pub fn checked_sub(self, other: Self) -> Result<Self> {
        let negated = other
            .numerator
            .checked_neg()
            .ok_or(MediaError::ArithmeticOverflow("rational subtraction"))?;
        self.checked_add(Self::new(negated, other.denominator)?)
    }

    pub fn checked_mul(self, other: Self) -> Result<Self> {
        let numerator = self
            .numerator
            .checked_mul(other.numerator)
            .ok_or(MediaError::ArithmeticOverflow("rational multiplication"))?;
        let denominator = self
            .denominator
            .checked_mul(other.denominator)
            .ok_or(MediaError::ArithmeticOverflow("rational multiplication"))?;
        Self::new(numerator, denominator)
    }

    pub fn checked_div(self, other: Self) -> Result<Self> {
        if other.numerator == 0 {
            return Err(MediaError::InvalidRequest("division by zero".into()));
        }
        let numerator = self
            .numerator
            .checked_mul(other.denominator)
            .ok_or(MediaError::ArithmeticOverflow("rational division"))?;
        let denominator = self
            .denominator
            .checked_mul(other.numerator)
            .ok_or(MediaError::ArithmeticOverflow("rational division"))?;
        Self::new(numerator, denominator)
    }

    pub fn checked_mul_integer(self, value: i128) -> Result<Self> {
        let numerator = self
            .numerator
            .checked_mul(value)
            .ok_or(MediaError::ArithmeticOverflow(
                "rational integer multiplication",
            ))?;
        Self::new(numerator, self.denominator)
    }

    pub fn checked_cmp(self, other: Self) -> Result<Ordering> {
        let left = self
            .numerator
            .checked_mul(other.denominator)
            .ok_or(MediaError::ArithmeticOverflow("rational comparison"))?;
        let right = other
            .numerator
            .checked_mul(self.denominator)
            .ok_or(MediaError::ArithmeticOverflow("rational comparison"))?;
        Ok(left.cmp(&right))
    }

    pub fn floor_i64(self) -> Result<i64> {
        let quotient = self.numerator / self.denominator;
        let remainder = self.numerator % self.denominator;
        let floor = if remainder < 0 {
            quotient
                .checked_sub(1)
                .ok_or(MediaError::ArithmeticOverflow("rational floor"))?
        } else {
            quotient
        };
        i64::try_from(floor).map_err(|_| MediaError::ArithmeticOverflow("rational floor"))
    }

    pub fn ceil_i64(self) -> Result<i64> {
        let quotient = self.numerator / self.denominator;
        let remainder = self.numerator % self.denominator;
        let ceil = if remainder > 0 {
            quotient
                .checked_add(1)
                .ok_or(MediaError::ArithmeticOverflow("rational ceiling"))?
        } else {
            quotient
        };
        i64::try_from(ceil).map_err(|_| MediaError::ArithmeticOverflow("rational ceiling"))
    }

    pub fn as_f64(self) -> f64 {
        self.numerator as f64 / self.denominator as f64
    }
}

impl TryFrom<RationalRepr> for ExactRational {
    type Error = MediaError;

    fn try_from(value: RationalRepr) -> Result<Self> {
        Self::new(value.numerator, value.denominator)
    }
}

impl From<ExactRational> for RationalRepr {
    fn from(value: ExactRational) -> Self {
        Self {
            numerator: value.numerator,
            denominator: value.denominator,
        }
    }
}

impl fmt::Display for ExactRational {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}/{}", self.numerator, self.denominator)
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "FrameRateRepr", into = "FrameRateRepr")]
pub struct FrameRate {
    numerator: u32,
    denominator: u32,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
struct FrameRateRepr {
    numerator: u32,
    denominator: u32,
}

impl FrameRate {
    pub fn new(numerator: u32, denominator: u32) -> Result<Self> {
        if numerator == 0 || denominator == 0 {
            return Err(MediaError::InvalidRequest(
                "frame-rate terms must be nonzero".into(),
            ));
        }
        let divisor = gcd(u128::from(numerator), u128::from(denominator)) as u32;
        Ok(Self {
            numerator: numerator / divisor,
            denominator: denominator / divisor,
        })
    }

    pub const fn numerator(self) -> u32 {
        self.numerator
    }

    pub const fn denominator(self) -> u32 {
        self.denominator
    }

    pub fn as_rational(self) -> ExactRational {
        ExactRational {
            numerator: i128::from(self.numerator),
            denominator: i128::from(self.denominator),
        }
    }

    pub fn frame_duration(self) -> ExactRational {
        ExactRational {
            numerator: i128::from(self.denominator),
            denominator: i128::from(self.numerator),
        }
    }
}

impl TryFrom<FrameRateRepr> for FrameRate {
    type Error = MediaError;

    fn try_from(value: FrameRateRepr) -> Result<Self> {
        Self::new(value.numerator, value.denominator)
    }
}

impl From<FrameRate> for FrameRateRepr {
    fn from(value: FrameRate) -> Self {
        Self {
            numerator: value.numerator,
            denominator: value.denominator,
        }
    }
}

impl fmt::Display for FrameRate {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}/{}", self.numerator, self.denominator)
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
pub struct MediaTime {
    seconds: ExactRational,
}

impl MediaTime {
    pub const ZERO: Self = Self {
        seconds: ExactRational::ZERO,
    };

    pub fn from_seconds(seconds: ExactRational) -> Self {
        Self { seconds }
    }

    pub fn from_micros(microseconds: i64) -> Result<Self> {
        Ok(Self {
            seconds: ExactRational::new(i128::from(microseconds), 1_000_000)?,
        })
    }

    pub const fn seconds(self) -> ExactRational {
        self.seconds
    }

    pub fn to_micros_floor(self) -> Result<i64> {
        self.seconds.checked_mul_integer(1_000_000)?.floor_i64()
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
pub struct FrameRange {
    pub start: u64,
    pub duration: u64,
}

impl FrameRange {
    pub fn new(start: u64, duration: u64) -> Result<Self> {
        if duration == 0 {
            return Err(MediaError::InvalidPlan(
                "clip duration must be greater than zero".into(),
            ));
        }
        start
            .checked_add(duration)
            .ok_or(MediaError::ArithmeticOverflow("frame range end"))?;
        Ok(Self { start, duration })
    }

    pub fn end(self) -> Result<u64> {
        self.start
            .checked_add(self.duration)
            .ok_or(MediaError::ArithmeticOverflow("frame range end"))
    }

    pub fn contains_position(self, position: ExactRational) -> Result<bool> {
        let start = ExactRational::from_integer(i128::from(self.start));
        let end = ExactRational::from_integer(i128::from(self.end()?));
        Ok(position.checked_cmp(start)? != Ordering::Less
            && position.checked_cmp(end)? == Ordering::Less)
    }
}

fn gcd(mut left: u128, mut right: u128) -> u128 {
    while right != 0 {
        let remainder = left % right;
        left = right;
        right = remainder;
    }
    left.max(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rational_operations_stay_reduced() {
        let value = ExactRational::new(24_000, 1_001)
            .unwrap()
            .checked_mul(ExactRational::new(1_001, 48_000).unwrap())
            .unwrap();

        assert_eq!(value, ExactRational::new(1, 2).unwrap());
    }

    #[test]
    fn negative_floor_is_mathematical_floor() {
        assert_eq!(ExactRational::new(-1, 2).unwrap().floor_i64().unwrap(), -1);
    }
}
