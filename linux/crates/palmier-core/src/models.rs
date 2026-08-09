use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::fmt;

use chrono::DateTime;
use serde::de::{self, DeserializeOwned, Visitor};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;
use thiserror::Error;
use uuid::Uuid;

use crate::frames::{Frame, FrameError, checked_add, swift_round};

pub fn new_id() -> String {
    Uuid::new_v4().hyphenated().to_string().to_uppercase()
}

fn deserialize_default<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de> + Default,
{
    Ok(T::deserialize(deserializer).unwrap_or_default())
}

fn deserialize_optional_tolerant<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Ok(Option::<T>::deserialize(deserializer).unwrap_or(None))
}

fn deserialize_normalized<'de, D>(deserializer: D) -> Result<f64, D::Error>
where
    D: Deserializer<'de>,
{
    let value = f64::deserialize(deserializer).unwrap_or_default();
    Ok(if (0.0..=1.0).contains(&value) {
        value
    } else {
        0.0
    })
}

fn deserialize_id<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    Ok(String::deserialize(deserializer).unwrap_or_else(|_| new_id()))
}

fn deserialize_timeline_name<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    Ok(String::deserialize(deserializer).unwrap_or_else(|_| default_timeline_name()))
}

fn deserialize_true<'de, D>(deserializer: D) -> Result<bool, D::Error>
where
    D: Deserializer<'de>,
{
    Ok(bool::deserialize(deserializer).unwrap_or(true))
}

fn deserialize_one<'de, D>(deserializer: D) -> Result<f64, D::Error>
where
    D: Deserializer<'de>,
{
    Ok(f64::deserialize(deserializer).unwrap_or(1.0))
}

fn deserialize_linear<'de, D>(deserializer: D) -> Result<Interpolation, D::Error>
where
    D: Deserializer<'de>,
{
    Ok(Interpolation::deserialize(deserializer).unwrap_or(Interpolation::Linear))
}

fn value_at<T: DeserializeOwned>(value: &Value, key: &str) -> Option<T> {
    value
        .get(key)
        .cloned()
        .and_then(|field| serde_json::from_value(field).ok())
}

fn default_timeline_name() -> String {
    "Timeline 1".to_owned()
}

fn default_fps() -> i32 {
    30
}

fn default_width() -> i32 {
    1920
}

fn default_height() -> i32 {
    1080
}

fn default_zoom_scale() -> f64 {
    4.0
}

fn default_track_height() -> f64 {
    44.0
}

fn deserialize_track_height<'de, D>(deserializer: D) -> Result<f64, D::Error>
where
    D: Deserializer<'de>,
{
    let height = f64::deserialize(deserializer).unwrap_or_else(|_| default_track_height());
    Ok(if height.is_finite() {
        height.clamp(32.0, 200.0)
    } else {
        default_track_height()
    })
}

fn default_true() -> bool {
    true
}

fn default_speed() -> f64 {
    1.0
}

fn default_volume() -> f64 {
    1.0
}

fn default_opacity() -> f64 {
    1.0
}

fn default_interpolation_linear() -> Interpolation {
    Interpolation::Linear
}

fn default_interpolation_smooth() -> Interpolation {
    Interpolation::Smooth
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ClipType {
    #[default]
    Video,
    Audio,
    Image,
    Text,
    Lottie,
    Sequence,
}

impl ClipType {
    pub fn is_visual(self) -> bool {
        self != Self::Audio
    }

    pub fn is_compatible_with(self, other: Self) -> bool {
        self == other || (self.is_visual() && other.is_visual())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Interpolation {
    Linear,
    Hold,
    #[default]
    Smooth,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Keyframe<T> {
    pub frame: Frame,
    pub value: T,
    #[serde(default = "default_interpolation_smooth")]
    pub interpolation_out: Interpolation,
}

impl<T> Keyframe<T> {
    pub fn new(frame: Frame, value: T) -> Self {
        Self {
            frame,
            value,
            interpolation_out: Interpolation::Smooth,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyframeTrack<T> {
    #[serde(default)]
    pub keyframes: Vec<Keyframe<T>>,
}

impl<T> Default for KeyframeTrack<T> {
    fn default() -> Self {
        Self {
            keyframes: Vec::new(),
        }
    }
}

impl<T: Clone + PartialEq> KeyframeTrack<T> {
    pub fn is_active(&self) -> bool {
        !self.keyframes.is_empty()
    }

    pub fn upsert(&mut self, keyframe: Keyframe<T>) {
        if let Some(index) = self
            .keyframes
            .iter()
            .position(|existing| existing.frame == keyframe.frame)
        {
            self.keyframes[index] = keyframe;
            return;
        }
        let index = self
            .keyframes
            .iter()
            .position(|existing| existing.frame > keyframe.frame)
            .unwrap_or(self.keyframes.len());
        self.keyframes.insert(index, keyframe);
    }

    pub fn remove(&mut self, frame: Frame) -> bool {
        let count = self.keyframes.len();
        self.keyframes.retain(|keyframe| keyframe.frame != frame);
        count != self.keyframes.len()
    }

    pub fn move_keyframe(&mut self, from: Frame, to: Frame) -> bool {
        let Some(index) = self
            .keyframes
            .iter()
            .position(|keyframe| keyframe.frame == from)
        else {
            return false;
        };
        if from != to && self.keyframes.iter().any(|keyframe| keyframe.frame == to) {
            return false;
        }
        let mut keyframe = self.keyframes.remove(index);
        keyframe.frame = to;
        self.upsert(keyframe);
        true
    }

    pub fn rescale(&mut self, scale: f64) -> Result<(), FrameError> {
        if !scale.is_finite() || scale <= 0.0 {
            return Err(FrameError::NonFinite);
        }
        let original = std::mem::take(&mut self.keyframes);
        for mut keyframe in original {
            keyframe.frame = swift_round(keyframe.frame as f64 * scale)?;
            self.upsert(keyframe);
        }
        Ok(())
    }

    pub fn clamp_to_duration(&mut self, duration: Frame) {
        self.keyframes
            .retain(|keyframe| keyframe.frame >= 0 && keyframe.frame <= duration);
    }
}

pub trait KeyframeInterpolatable: Clone {
    fn interpolate(from: &Self, to: &Self, t: f64) -> Self;
}

impl KeyframeInterpolatable for f64 {
    fn interpolate(from: &Self, to: &Self, t: f64) -> Self {
        from + (to - from) * t
    }
}

impl<T> KeyframeTrack<T>
where
    T: KeyframeInterpolatable + Clone + PartialEq,
{
    pub fn sample(&self, frame: Frame, fallback: T) -> T {
        let Some(first) = self.keyframes.first() else {
            return fallback;
        };
        if self.keyframes.len() == 1 || frame <= first.frame {
            return first.value.clone();
        }
        let last = self.keyframes.last().expect("a first keyframe exists");
        if frame >= last.frame {
            return last.value.clone();
        }
        let upper_index = self
            .keyframes
            .iter()
            .position(|keyframe| keyframe.frame > frame)
            .expect("the last keyframe is after the sample");
        let lower = &self.keyframes[upper_index - 1];
        let upper = &self.keyframes[upper_index];
        let raw = (frame - lower.frame) as f64 / (upper.frame - lower.frame) as f64;
        match lower.interpolation_out {
            Interpolation::Hold => lower.value.clone(),
            Interpolation::Linear => T::interpolate(&lower.value, &upper.value, raw),
            Interpolation::Smooth => T::interpolate(&lower.value, &upper.value, smoothstep(raw)),
        }
    }

    pub fn rebased(&self, offset: Frame, fallback: T) -> Option<Self> {
        if !self.is_active() {
            return None;
        }
        let boundary = self.sample(offset, fallback);
        let mut keyframes: Vec<_> = self
            .keyframes
            .iter()
            .filter(|keyframe| keyframe.frame >= offset)
            .cloned()
            .map(|mut keyframe| {
                keyframe.frame -= offset;
                keyframe
            })
            .collect();
        if keyframes.first().map(|keyframe| keyframe.frame) != Some(0) {
            let interpolation_out = self
                .keyframes
                .iter()
                .rev()
                .find(|keyframe| keyframe.frame < offset)
                .map(|keyframe| keyframe.interpolation_out)
                .unwrap_or(Interpolation::Smooth);
            keyframes.insert(
                0,
                Keyframe {
                    frame: 0,
                    value: boundary,
                    interpolation_out,
                },
            );
        }
        Some(Self { keyframes })
    }
}

pub fn smoothstep(t: f64) -> f64 {
    t * t * (3.0 - 2.0 * t)
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct AnimPair {
    pub a: f64,
    pub b: f64,
}

impl KeyframeInterpolatable for AnimPair {
    fn interpolate(from: &Self, to: &Self, t: f64) -> Self {
        Self {
            a: f64::interpolate(&from.a, &to.a, t),
            b: f64::interpolate(&from.b, &to.b, t),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct Crop {
    pub left: f64,
    pub top: f64,
    pub right: f64,
    pub bottom: f64,
}

impl Crop {
    pub fn is_identity(self) -> bool {
        self == Self::default()
    }

    pub fn visible_width_fraction(self) -> f64 {
        (1.0 - self.left - self.right).max(0.0)
    }

    pub fn visible_height_fraction(self) -> f64 {
        (1.0 - self.top - self.bottom).max(0.0)
    }
}

impl KeyframeInterpolatable for Crop {
    fn interpolate(from: &Self, to: &Self, t: f64) -> Self {
        Self {
            left: f64::interpolate(&from.left, &to.left, t),
            top: f64::interpolate(&from.top, &to.top, t),
            right: f64::interpolate(&from.right, &to.right, t),
            bottom: f64::interpolate(&from.bottom, &to.bottom, t),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Transform {
    pub center_x: f64,
    pub center_y: f64,
    pub width: f64,
    pub height: f64,
    pub rotation: f64,
    pub flip_horizontal: bool,
    pub flip_vertical: bool,
}

impl Default for Transform {
    fn default() -> Self {
        Self {
            center_x: 0.5,
            center_y: 0.5,
            width: 1.0,
            height: 1.0,
            rotation: 0.0,
            flip_horizontal: false,
            flip_vertical: false,
        }
    }
}

impl<'de> Deserialize<'de> for Transform {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Default, Deserialize)]
        #[serde(rename_all = "camelCase", default)]
        struct Raw {
            center_x: Option<f64>,
            center_y: Option<f64>,
            width: Option<f64>,
            height: Option<f64>,
            rotation: Option<f64>,
            flip_horizontal: Option<bool>,
            flip_vertical: Option<bool>,
            x: Option<f64>,
            y: Option<f64>,
        }

        let raw = Raw::deserialize(deserializer)?;
        let width = raw.width.unwrap_or(1.0);
        let height = raw.height.unwrap_or(1.0);
        Ok(Self {
            center_x: raw
                .center_x
                .or_else(|| raw.x.map(|x| x + width - 0.5))
                .unwrap_or(0.5),
            center_y: raw
                .center_y
                .or_else(|| raw.y.map(|y| y + height - 0.5))
                .unwrap_or(0.5),
            width,
            height,
            rotation: raw.rotation.unwrap_or(0.0),
            flip_horizontal: raw.flip_horizontal.unwrap_or(false),
            flip_vertical: raw.flip_vertical.unwrap_or(false),
        })
    }
}

impl Transform {
    pub fn top_left(self) -> AnimPair {
        AnimPair {
            a: self.center_x - self.width / 2.0,
            b: self.center_y - self.height / 2.0,
        }
    }

    pub fn from_top_left(top_left: AnimPair, width: f64, height: f64) -> Self {
        Self {
            center_x: top_left.a + width / 2.0,
            center_y: top_left.b + height / 2.0,
            width,
            height,
            ..Self::default()
        }
    }

    pub fn snap_to_boundary(value: f64, threshold: f64) -> f64 {
        if value.abs() < threshold {
            0.0
        } else if (value - 1.0).abs() < threshold {
            1.0
        } else {
            value
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Rgba {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
}

impl Default for Rgba {
    fn default() -> Self {
        Self {
            r: 1.0,
            g: 1.0,
            b: 1.0,
            a: 1.0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum TextAlignment {
    Left,
    #[default]
    Center,
    Right,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum FontCase {
    #[default]
    Mixed,
    Uppercase,
    Lowercase,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TextShadow {
    pub enabled: bool,
    pub color: Rgba,
    pub offset_x: f64,
    pub offset_y: f64,
    pub blur: f64,
}

impl Default for TextShadow {
    fn default() -> Self {
        Self {
            enabled: false,
            color: Rgba {
                r: 0.0,
                g: 0.0,
                b: 0.0,
                a: 0.6,
            },
            offset_x: 0.0,
            offset_y: -2.0,
            blur: 6.0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TextOutline {
    pub enabled: bool,
    pub color: Rgba,
    pub width: f64,
}

impl Default for TextOutline {
    fn default() -> Self {
        Self {
            enabled: false,
            color: Rgba {
                r: 0.0,
                g: 0.0,
                b: 0.0,
                a: 1.0,
            },
            width: 4.0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TextBackground {
    pub enabled: bool,
    pub color: Rgba,
    pub padding_x: f64,
    pub padding_y: f64,
    pub corner_radius: f64,
    pub offset_x: f64,
    pub offset_y: f64,
    pub outline_color: Rgba,
    pub outline_width: f64,
}

impl Default for TextBackground {
    fn default() -> Self {
        Self {
            enabled: false,
            color: Rgba {
                r: 0.0,
                g: 0.0,
                b: 0.0,
                a: 0.6,
            },
            padding_x: 0.0,
            padding_y: 0.0,
            corner_radius: 0.0,
            offset_x: 0.0,
            offset_y: 0.0,
            outline_color: Rgba {
                r: 0.0,
                g: 0.0,
                b: 0.0,
                a: 1.0,
            },
            outline_width: 0.0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TextStyle {
    pub font_name: String,
    pub font_size: f64,
    pub font_scale: f64,
    pub width_scale: f64,
    pub height_scale: f64,
    pub tracking: f64,
    pub line_spacing: f64,
    pub font_case: FontCase,
    pub is_bold: bool,
    pub is_italic: bool,
    pub is_underlined: bool,
    pub is_struck_through: bool,
    pub is_overlined: bool,
    pub color: Rgba,
    pub alignment: TextAlignment,
    pub shadow: TextShadow,
    pub background: TextBackground,
    pub border: TextOutline,
}

impl Default for TextStyle {
    fn default() -> Self {
        Self {
            font_name: "Helvetica".to_owned(),
            font_size: 96.0,
            font_scale: 1.0,
            width_scale: 1.0,
            height_scale: 1.0,
            tracking: 0.0,
            line_spacing: 0.0,
            font_case: FontCase::Mixed,
            is_bold: false,
            is_italic: false,
            is_underlined: false,
            is_struck_through: false,
            is_overlined: false,
            color: Rgba::default(),
            alignment: TextAlignment::Center,
            shadow: TextShadow::default(),
            background: TextBackground::default(),
            border: TextOutline::default(),
        }
    }
}

impl<'de> Deserialize<'de> for TextStyle {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = Value::deserialize(deserializer)?;
        let mut style = Self::default();
        if let Some(field) = value_at(&value, "fontName") {
            style.font_name = field;
        }
        if let Some(field) = value_at(&value, "fontSize") {
            style.font_size = field;
        }
        if let Some(field) = value_at(&value, "fontScale") {
            style.font_scale = field;
        }
        if let Some(field) = value_at(&value, "widthScale") {
            style.width_scale = field;
        }
        if let Some(field) = value_at(&value, "heightScale") {
            style.height_scale = field;
        }
        if let Some(field) = value_at(&value, "tracking") {
            style.tracking = field;
        }
        if let Some(field) = value_at(&value, "lineSpacing") {
            style.line_spacing = field;
        }
        if let Some(field) = value_at(&value, "fontCase") {
            style.font_case = field;
        }
        let lowered_name = style.font_name.to_ascii_lowercase();
        style.is_bold = value_at(&value, "isBold").unwrap_or_else(|| {
            ["bold", "semibold", "demibold", "heavy", "black"]
                .iter()
                .any(|trait_name| lowered_name.contains(trait_name))
        });
        style.is_italic = value_at(&value, "isItalic").unwrap_or_else(|| {
            ["italic", "oblique"]
                .iter()
                .any(|trait_name| lowered_name.contains(trait_name))
        });
        style.is_underlined = value_at(&value, "isUnderlined").unwrap_or(false);
        style.is_struck_through = value_at(&value, "isStruckThrough").unwrap_or(false);
        style.is_overlined = value_at(&value, "isOverlined").unwrap_or(false);
        if let Some(field) = value_at(&value, "color") {
            style.color = field;
        }
        if let Some(field) = value_at(&value, "alignment") {
            style.alignment = field;
        }
        if let Some(field) = value_at(&value, "shadow") {
            style.shadow = field;
        }
        if let Some(field) = value_at(&value, "background") {
            style.background = field;
        }
        if let Some(field) = value_at(&value, "border") {
            style.border = field;
        }
        Ok(style)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WordTiming {
    pub text: String,
    pub start_frame: Frame,
    pub end_frame: Frame,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum TextAnimationPreset {
    #[default]
    None,
    FadeIn,
    PopIn,
    SlideUp,
    Typewriter,
    WordReveal,
    WordSlide,
    WordPop,
    WordCycle,
    HighlightPop,
    HighlightBlock,
}

fn default_per_word_frames() -> Frame {
    6
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TextAnimation {
    pub preset: TextAnimationPreset,
    #[serde(default = "default_per_word_frames")]
    pub per_word_frames: Frame,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub highlight: Option<Rgba>,
}

impl Default for TextAnimation {
    fn default() -> Self {
        Self {
            preset: TextAnimationPreset::None,
            per_word_frames: default_per_word_frames(),
            highlight: None,
        }
    }
}

impl<'de> Deserialize<'de> for TextAnimation {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = Value::deserialize(deserializer)?;
        Ok(Self {
            preset: value_at(&value, "preset").unwrap_or_default(),
            per_word_frames: value_at(&value, "perWordFrames")
                .unwrap_or_else(default_per_word_frames),
            highlight: value_at(&value, "highlight"),
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TextFillMode {
    Color,
    Footage,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BlendMode {
    Normal,
    Darken,
    Multiply,
    ColorBurn,
    Lighten,
    Screen,
    ColorDodge,
    Overlay,
    SoftLight,
    HardLight,
    Difference,
    Exclusion,
    Hue,
    Saturation,
    Color,
    Luminosity,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct EffectParam {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub string: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track: Option<KeyframeTrack<f64>>,
}

impl EffectParam {
    pub fn resolved(&self, offset: Frame, default: f64) -> f64 {
        if let Some(track) = &self.track
            && track.is_active()
        {
            return track.sample(offset, self.value.unwrap_or(default));
        }
        self.value.unwrap_or(default)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Effect {
    #[serde(default = "new_id", deserialize_with = "deserialize_id")]
    pub id: String,
    #[serde(rename = "type")]
    pub effect_type: String,
    #[serde(default = "default_true", deserialize_with = "deserialize_true")]
    pub enabled: bool,
    #[serde(default, deserialize_with = "deserialize_default")]
    pub params: BTreeMap<String, EffectParam>,
}

impl Effect {
    pub fn new(effect_type: impl Into<String>) -> Self {
        Self {
            id: new_id(),
            effect_type: effect_type.into(),
            enabled: true,
            params: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Clip {
    #[serde(default = "new_id", deserialize_with = "deserialize_id")]
    pub id: String,
    pub media_ref: String,
    #[serde(default, deserialize_with = "deserialize_default")]
    pub media_type: ClipType,
    #[serde(default, deserialize_with = "deserialize_default")]
    pub source_clip_type: ClipType,
    pub start_frame: Frame,
    pub duration_frames: Frame,
    #[serde(default, deserialize_with = "deserialize_default")]
    pub trim_start_frame: Frame,
    #[serde(default, deserialize_with = "deserialize_default")]
    pub trim_end_frame: Frame,
    #[serde(default = "default_speed", deserialize_with = "deserialize_one")]
    pub speed: f64,
    #[serde(default = "default_volume", deserialize_with = "deserialize_one")]
    pub volume: f64,
    #[serde(default, deserialize_with = "deserialize_default")]
    pub fade_in_frames: Frame,
    #[serde(default, deserialize_with = "deserialize_default")]
    pub fade_out_frames: Frame,
    #[serde(
        default = "default_interpolation_linear",
        deserialize_with = "deserialize_linear"
    )]
    pub fade_in_interpolation: Interpolation,
    #[serde(
        default = "default_interpolation_linear",
        deserialize_with = "deserialize_linear"
    )]
    pub fade_out_interpolation: Interpolation,
    #[serde(default = "default_opacity", deserialize_with = "deserialize_one")]
    pub opacity: f64,
    #[serde(default, deserialize_with = "deserialize_default")]
    pub transform: Transform,
    #[serde(default, deserialize_with = "deserialize_default")]
    pub crop: Crop,
    #[serde(default, deserialize_with = "deserialize_normalized")]
    pub edge_rounding: f64,
    #[serde(default, deserialize_with = "deserialize_normalized")]
    pub edge_softness: f64,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_tolerant",
        skip_serializing_if = "Option::is_none"
    )]
    pub link_group_id: Option<String>,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_tolerant",
        skip_serializing_if = "Option::is_none"
    )]
    pub caption_group_id: Option<String>,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_tolerant",
        skip_serializing_if = "Option::is_none"
    )]
    pub multicam_group_id: Option<String>,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_tolerant",
        skip_serializing_if = "Option::is_none"
    )]
    pub text_content: Option<String>,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_tolerant",
        skip_serializing_if = "Option::is_none"
    )]
    pub text_style: Option<TextStyle>,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_tolerant",
        skip_serializing_if = "Option::is_none"
    )]
    pub text_animation: Option<TextAnimation>,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_tolerant",
        skip_serializing_if = "Option::is_none"
    )]
    pub word_timings: Option<Vec<WordTiming>>,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_tolerant",
        skip_serializing_if = "Option::is_none"
    )]
    pub text_fill_mode: Option<TextFillMode>,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_tolerant",
        skip_serializing_if = "Option::is_none"
    )]
    pub opacity_track: Option<KeyframeTrack<f64>>,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_tolerant",
        skip_serializing_if = "Option::is_none"
    )]
    pub position_track: Option<KeyframeTrack<AnimPair>>,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_tolerant",
        skip_serializing_if = "Option::is_none"
    )]
    pub scale_track: Option<KeyframeTrack<AnimPair>>,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_tolerant",
        skip_serializing_if = "Option::is_none"
    )]
    pub rotation_track: Option<KeyframeTrack<f64>>,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_tolerant",
        skip_serializing_if = "Option::is_none"
    )]
    pub crop_track: Option<KeyframeTrack<Crop>>,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_tolerant",
        skip_serializing_if = "Option::is_none"
    )]
    pub volume_track: Option<KeyframeTrack<f64>>,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_tolerant",
        skip_serializing_if = "Option::is_none"
    )]
    pub effects: Option<Vec<Effect>>,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_tolerant",
        skip_serializing_if = "Option::is_none"
    )]
    pub blend_mode: Option<BlendMode>,
}

impl Clip {
    pub fn new(media_ref: impl Into<String>, start_frame: Frame, duration_frames: Frame) -> Self {
        Self {
            id: new_id(),
            media_ref: media_ref.into(),
            media_type: ClipType::Video,
            source_clip_type: ClipType::Video,
            start_frame,
            duration_frames,
            trim_start_frame: 0,
            trim_end_frame: 0,
            speed: 1.0,
            volume: 1.0,
            fade_in_frames: 0,
            fade_out_frames: 0,
            fade_in_interpolation: Interpolation::Linear,
            fade_out_interpolation: Interpolation::Linear,
            opacity: 1.0,
            transform: Transform::default(),
            crop: Crop::default(),
            edge_rounding: 0.0,
            edge_softness: 0.0,
            link_group_id: None,
            caption_group_id: None,
            multicam_group_id: None,
            text_content: None,
            text_style: None,
            text_animation: None,
            word_timings: None,
            text_fill_mode: None,
            opacity_track: None,
            position_track: None,
            scale_track: None,
            rotation_track: None,
            crop_track: None,
            volume_track: None,
            effects: None,
            blend_mode: None,
        }
    }

    pub fn checked_end_frame(&self) -> Result<Frame, FrameError> {
        checked_add(self.start_frame, self.duration_frames)
    }

    pub fn end_frame(&self) -> Frame {
        self.start_frame.saturating_add(self.duration_frames)
    }

    pub fn contains(&self, timeline_frame: Frame) -> bool {
        timeline_frame >= self.start_frame && timeline_frame < self.end_frame()
    }

    pub fn supports_retiming(&self) -> bool {
        self.source_clip_type != ClipType::Sequence
    }

    pub fn source_frames_consumed(&self) -> Result<Frame, FrameError> {
        swift_round(self.duration_frames as f64 * self.speed)
    }

    pub fn source_duration_frames(&self) -> Result<Frame, FrameError> {
        let consumed = self.source_frames_consumed()?;
        checked_add(
            checked_add(consumed, self.trim_start_frame)?,
            self.trim_end_frame,
        )
    }

    pub fn timeline_frame(
        &self,
        source_seconds: f64,
        fps: i32,
    ) -> Result<Option<Frame>, FrameError> {
        if fps <= 0 {
            return Err(FrameError::InvalidFps);
        }
        if !source_seconds.is_finite() {
            return Err(FrameError::NonFinite);
        }
        let source_frame = source_seconds * f64::from(fps);
        let offset_from_trim = source_frame - self.trim_start_frame as f64;
        if offset_from_trim < 0.0 {
            return Ok(None);
        }
        let speed = self.speed.max(0.0001);
        let frame = swift_round(self.start_frame as f64 + offset_from_trim / speed)?;
        Ok((frame >= self.start_frame && frame < self.end_frame()).then_some(frame))
    }

    fn keyframe_offset(&self, frame: Frame) -> Frame {
        frame - self.start_frame
    }

    pub fn raw_opacity_at(&self, frame: Frame) -> f64 {
        self.opacity_track
            .as_ref()
            .map(|track| track.sample(self.keyframe_offset(frame), self.opacity))
            .unwrap_or(self.opacity)
    }

    pub fn opacity_at(&self, frame: Frame) -> f64 {
        let base = self.raw_opacity_at(frame);
        if self.media_type == ClipType::Audio
            || (self.fade_in_frames == 0 && self.fade_out_frames == 0)
        {
            base
        } else {
            base * self.fade_multiplier(frame)
        }
    }

    pub fn rotation_at(&self, frame: Frame) -> f64 {
        self.rotation_track
            .as_ref()
            .map(|track| track.sample(self.keyframe_offset(frame), self.transform.rotation))
            .unwrap_or(self.transform.rotation)
    }

    pub fn top_left_at(&self, frame: Frame) -> AnimPair {
        if let Some(track) = &self.position_track
            && track.is_active()
        {
            return track.sample(self.keyframe_offset(frame), AnimPair::default());
        }
        let size = self.size_at(frame);
        AnimPair {
            a: self.transform.center_x - size.a / 2.0,
            b: self.transform.center_y - size.b / 2.0,
        }
    }

    pub fn size_at(&self, frame: Frame) -> AnimPair {
        let fallback = AnimPair {
            a: self.transform.width,
            b: self.transform.height,
        };
        self.scale_track
            .as_ref()
            .map(|track| track.sample(self.keyframe_offset(frame), fallback))
            .unwrap_or(fallback)
    }

    pub fn transform_at(&self, frame: Frame) -> Transform {
        let top_left = self.top_left_at(frame);
        let size = self.size_at(frame);
        Transform {
            center_x: top_left.a + size.a / 2.0,
            center_y: top_left.b + size.b / 2.0,
            width: size.a,
            height: size.b,
            rotation: self.rotation_at(frame),
            ..self.transform
        }
    }

    pub fn crop_at(&self, frame: Frame) -> Crop {
        self.crop_track
            .as_ref()
            .map(|track| track.sample(self.keyframe_offset(frame), self.crop))
            .unwrap_or(self.crop)
    }

    pub fn fade_multiplier(&self, frame: Frame) -> f64 {
        let relative = frame - self.start_frame;
        if relative < 0 || relative > self.duration_frames {
            return 0.0;
        }
        let fade_in = if self.fade_in_frames > 0 {
            let value = (relative as f64 / self.fade_in_frames as f64).min(1.0);
            if self.fade_in_interpolation == Interpolation::Smooth {
                smoothstep(value)
            } else {
                value
            }
        } else {
            1.0
        };
        let remaining = self.duration_frames - relative;
        let fade_out = if self.fade_out_frames > 0 {
            let value = (remaining as f64 / self.fade_out_frames as f64).min(1.0);
            if self.fade_out_interpolation == Interpolation::Smooth {
                smoothstep(value)
            } else {
                value
            }
        } else {
            1.0
        };
        fade_in.min(fade_out)
    }

    pub fn raw_volume_at(&self, frame: Frame) -> f64 {
        let keyframe_gain = self
            .volume_track
            .as_ref()
            .filter(|track| track.is_active())
            .map(|track| {
                let decibels = track.sample(self.keyframe_offset(frame), 0.0);
                10_f64.powf(decibels / 20.0)
            })
            .unwrap_or(1.0);
        self.volume * keyframe_gain
    }

    pub fn volume_at(&self, frame: Frame) -> f64 {
        self.raw_volume_at(frame) * self.fade_multiplier(frame)
    }

    pub fn clamp_fades_to_duration(&mut self) {
        self.fade_in_frames = self.fade_in_frames.clamp(0, self.duration_frames.max(0));
        self.fade_out_frames = self
            .fade_out_frames
            .clamp(0, (self.duration_frames - self.fade_in_frames).max(0));
    }

    pub fn clamp_keyframes_to_duration(&mut self) {
        clamp_track(&mut self.opacity_track, self.duration_frames);
        clamp_track(&mut self.position_track, self.duration_frames);
        clamp_track(&mut self.scale_track, self.duration_frames);
        clamp_track(&mut self.rotation_track, self.duration_frames);
        clamp_track(&mut self.crop_track, self.duration_frames);
        clamp_track(&mut self.volume_track, self.duration_frames);
    }

    pub fn rescale_keyframes(&mut self, scale: f64) -> Result<(), FrameError> {
        rescale_track(&mut self.opacity_track, scale)?;
        rescale_track(&mut self.position_track, scale)?;
        rescale_track(&mut self.scale_track, scale)?;
        rescale_track(&mut self.rotation_track, scale)?;
        rescale_track(&mut self.crop_track, scale)?;
        rescale_track(&mut self.volume_track, scale)?;
        Ok(())
    }

    pub fn set_duration(&mut self, duration: Frame) {
        let old_duration = self.duration_frames;
        self.duration_frames = duration;
        if self.media_type == ClipType::Text && old_duration > 0 && duration > 0 {
            if let Some(timings) = &mut self.word_timings {
                let scale = duration as f64 / old_duration as f64;
                for timing in timings {
                    let start = swift_round(timing.start_frame as f64 * scale)
                        .unwrap_or(0)
                        .clamp(0, (duration - 1).max(0));
                    let end = swift_round(timing.end_frame as f64 * scale)
                        .unwrap_or(duration)
                        .max(start + 1)
                        .clamp(0, duration);
                    timing.start_frame = start;
                    timing.end_frame = end;
                }
            }
        }
        self.clamp_keyframes_to_duration();
        self.clamp_fades_to_duration();
    }

    pub fn freshen_ids(&mut self, groups: &mut HashMap<String, String>) {
        fn remap(value: &mut Option<String>, groups: &mut HashMap<String, String>) {
            let Some(old) = value.clone() else {
                return;
            };
            let fresh = groups.entry(old).or_insert_with(new_id).clone();
            *value = Some(fresh);
        }
        self.id = new_id();
        remap(&mut self.link_group_id, groups);
        remap(&mut self.caption_group_id, groups);
    }
}

fn clamp_track<T: Clone + PartialEq>(track: &mut Option<KeyframeTrack<T>>, duration: Frame) {
    if let Some(existing) = track {
        existing.clamp_to_duration(duration);
        if existing.keyframes.is_empty() {
            *track = None;
        }
    }
}

fn rescale_track<T: Clone + PartialEq>(
    track: &mut Option<KeyframeTrack<T>>,
    scale: f64,
) -> Result<(), FrameError> {
    if let Some(existing) = track {
        existing.rescale(scale)?;
        if existing.keyframes.is_empty() {
            *track = None;
        }
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AnimatableProperty {
    Opacity,
    Position,
    Scale,
    Rotation,
    Crop,
    Volume,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum KeyframeValue {
    Number(f64),
    Pair(AnimPair),
    Crop(Crop),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Track {
    #[serde(default = "new_id", deserialize_with = "deserialize_id")]
    pub id: String,
    #[serde(rename = "type")]
    pub track_type: ClipType,
    #[serde(default, deserialize_with = "deserialize_default")]
    pub muted: bool,
    #[serde(default, deserialize_with = "deserialize_default")]
    pub hidden: bool,
    #[serde(default = "default_true", deserialize_with = "deserialize_true")]
    pub sync_locked: bool,
    #[serde(default, deserialize_with = "deserialize_default")]
    pub clips: Vec<Clip>,
    #[serde(
        default = "default_track_height",
        deserialize_with = "deserialize_track_height"
    )]
    pub display_height: f64,
}

impl Track {
    pub fn new(track_type: ClipType) -> Self {
        Self {
            id: new_id(),
            track_type,
            muted: false,
            hidden: false,
            sync_locked: true,
            clips: Vec::new(),
            display_height: default_track_height(),
        }
    }

    pub fn end_frame(&self) -> Frame {
        self.clips.iter().map(Clip::end_frame).max().unwrap_or(0)
    }

    pub fn contiguous_clip_ids(&self, from_end: Frame, exclude_id: &str) -> HashSet<String> {
        let mut clips: Vec<_> = self
            .clips
            .iter()
            .filter(|clip| clip.id != exclude_id && clip.start_frame >= from_end)
            .collect();
        clips.sort_by_key(|clip| clip.start_frame);
        let mut ids = HashSet::new();
        let mut chain_end = from_end;
        for clip in clips {
            if clip.start_frame != chain_end {
                break;
            }
            chain_end = clip.end_frame();
            ids.insert(clip.id.clone());
        }
        ids
    }

    pub fn sort_clips(&mut self) {
        self.clips
            .sort_by(|left, right| left.start_frame.cmp(&right.start_frame));
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelineViewState {
    #[serde(default)]
    pub playhead_frame: Frame,
    #[serde(default = "default_zoom_scale")]
    pub zoom_scale: f64,
    #[serde(default)]
    pub scroll_offset_x: f64,
}

impl Default for TimelineViewState {
    fn default() -> Self {
        Self {
            playhead_frame: 0,
            zoom_scale: default_zoom_scale(),
            scroll_offset_x: 0.0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Timeline {
    #[serde(default = "new_id", deserialize_with = "deserialize_id")]
    pub id: String,
    #[serde(
        default = "default_timeline_name",
        deserialize_with = "deserialize_timeline_name"
    )]
    pub name: String,
    pub fps: i32,
    pub width: i32,
    pub height: i32,
    #[serde(default, deserialize_with = "deserialize_default")]
    pub settings_configured: bool,
    #[serde(
        default,
        deserialize_with = "deserialize_optional_tolerant",
        skip_serializing_if = "Option::is_none"
    )]
    pub folder_id: Option<String>,
    pub tracks: Vec<Track>,
}

impl Default for Timeline {
    fn default() -> Self {
        Self {
            id: new_id(),
            name: default_timeline_name(),
            fps: default_fps(),
            width: default_width(),
            height: default_height(),
            settings_configured: false,
            folder_id: None,
            tracks: Vec::new(),
        }
    }
}

impl Timeline {
    pub fn total_frames(&self) -> Frame {
        self.tracks.iter().map(Track::end_frame).max().unwrap_or(0)
    }

    pub fn has_audio_clips(&self) -> bool {
        self.tracks
            .iter()
            .any(|track| track.track_type == ClipType::Audio && !track.clips.is_empty())
    }

    pub fn clip_location(&self, clip_id: &str) -> Option<ClipLocation> {
        self.tracks
            .iter()
            .enumerate()
            .find_map(|(track_index, track)| {
                track
                    .clips
                    .iter()
                    .position(|clip| clip.id == clip_id)
                    .map(|clip_index| ClipLocation {
                        track_index,
                        clip_index,
                    })
            })
    }

    pub fn reachable_timeline_ids(&self, timelines: &[Timeline], max_depth: usize) -> Vec<String> {
        let by_id: HashMap<_, _> = timelines
            .iter()
            .map(|timeline| (timeline.id.as_str(), timeline))
            .collect();
        let mut found = Vec::new();
        let mut seen = HashSet::from([self.id.as_str()]);
        let mut queue = VecDeque::from([(self, 0_usize)]);
        while let Some((timeline, depth)) = queue.pop_front() {
            if depth >= max_depth {
                continue;
            }
            for clip in timeline.tracks.iter().flat_map(|track| &track.clips) {
                if clip.source_clip_type != ClipType::Sequence
                    || !seen.insert(clip.media_ref.as_str())
                {
                    continue;
                }
                if let Some(child) = by_id.get(clip.media_ref.as_str()) {
                    found.push(child.id.clone());
                    queue.push_back((child, depth + 1));
                }
            }
        }
        found
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClipLocation {
    pub track_index: usize,
    pub clip_index: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpeakerRegistryEntry {
    pub id: i32,
    pub name: String,
    pub color: Vec<f64>,
    pub centroid: Vec<f32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct MulticamSyncMap {
    pub offset_seconds: f64,
    pub confidence: f64,
    pub locked: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MulticamMemberKind {
    Angle,
    Mic,
    Both,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MulticamMember {
    #[serde(default = "new_id")]
    pub id: String,
    pub media_ref: String,
    pub kind: MulticamMemberKind,
    pub angle_label: String,
    #[serde(default)]
    pub sync: MulticamSyncMap,
}

impl MulticamMember {
    pub fn provides_video(&self) -> bool {
        self.kind != MulticamMemberKind::Mic
    }

    pub fn provides_audio(&self) -> bool {
        self.kind != MulticamMemberKind::Angle
    }

    pub fn usable(&self) -> bool {
        self.sync.confidence > 0.0 || self.sync.locked
    }

    pub fn offset_frames(&self, fps: i32) -> Result<Frame, FrameError> {
        swift_round(self.sync.offset_seconds * f64::from(fps))
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MulticamSource {
    #[serde(default = "new_id")]
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub members: Vec<MulticamMember>,
    #[serde(default)]
    pub master_member_id: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectFile {
    pub timelines: Vec<Timeline>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_timeline_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub open_timeline_ids: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub view_states: Option<BTreeMap<String, TimelineViewState>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speakers: Option<Vec<SpeakerRegistryEntry>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub multicam_groups: Option<Vec<MulticamSource>>,
}

impl ProjectFile {
    pub fn new(timelines: Vec<Timeline>) -> Result<Self, ProjectDecodeError> {
        if timelines.is_empty() {
            return Err(ProjectDecodeError::NoTimelines);
        }
        let active_timeline_id = timelines.first().map(|timeline| timeline.id.clone());
        Ok(Self {
            open_timeline_ids: active_timeline_id.clone().map(|id| vec![id]),
            active_timeline_id,
            timelines,
            view_states: None,
            speakers: None,
            multicam_groups: None,
        })
    }

    pub fn decode_json(data: &[u8]) -> Result<Self, ProjectDecodeError> {
        match serde_json::from_slice::<Self>(data) {
            Ok(project) if project.timelines.is_empty() => Err(ProjectDecodeError::NoTimelines),
            Ok(project) => Ok(project),
            Err(project_error) => match serde_json::from_slice::<Timeline>(data) {
                Ok(timeline) => Self::new(vec![timeline]),
                Err(_) => Err(ProjectDecodeError::Json(project_error)),
            },
        }
    }

    pub fn encode_json(&self) -> Result<Vec<u8>, serde_json::Error> {
        serde_json::to_vec(self)
    }

    pub fn active_timeline_id(&self) -> Option<&str> {
        self.active_timeline_id
            .as_deref()
            .filter(|id| self.timelines.iter().any(|timeline| timeline.id == *id))
            .or_else(|| self.timelines.first().map(|timeline| timeline.id.as_str()))
    }

    pub fn normalize_navigation(&mut self) {
        let valid_ids: HashSet<_> = self
            .timelines
            .iter()
            .map(|timeline| timeline.id.clone())
            .collect();
        let fallback = self.timelines.first().map(|timeline| timeline.id.clone());
        if self
            .active_timeline_id
            .as_ref()
            .is_none_or(|id| !valid_ids.contains(id))
        {
            self.active_timeline_id = fallback.clone();
        }
        let mut open = self.open_timeline_ids.take().unwrap_or_default();
        open.retain(|id| valid_ids.contains(id));
        let mut seen = HashSet::new();
        open.retain(|id| seen.insert(id.clone()));
        if let Some(active) = &self.active_timeline_id
            && !open.contains(active)
        {
            open.push(active.clone());
        }
        self.open_timeline_ids = Some(open);
    }
}

#[derive(Debug, Error)]
pub enum ProjectDecodeError {
    #[error("project has no timelines")]
    NoTimelines,
    #[error("project JSON is invalid: {0}")]
    Json(#[from] serde_json::Error),
}

#[derive(Debug, Clone, Copy, PartialEq, PartialOrd, Default)]
pub struct SwiftDate(pub f64);

impl SwiftDate {
    pub const APPLE_REFERENCE_UNIX_SECONDS: f64 = 978_307_200.0;

    pub fn from_unix_seconds(seconds: f64) -> Self {
        Self(seconds - Self::APPLE_REFERENCE_UNIX_SECONDS)
    }

    pub fn unix_seconds(self) -> f64 {
        self.0 + Self::APPLE_REFERENCE_UNIX_SECONDS
    }
}

impl Serialize for SwiftDate {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        if !self.0.is_finite() {
            return Err(serde::ser::Error::custom("date must be finite"));
        }
        serializer.serialize_f64(self.0)
    }
}

impl<'de> Deserialize<'de> for SwiftDate {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct SwiftDateVisitor;

        impl Visitor<'_> for SwiftDateVisitor {
            type Value = SwiftDate;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("Swift reference-date seconds or an RFC 3339 date")
            }

            fn visit_f64<E>(self, value: f64) -> Result<Self::Value, E>
            where
                E: de::Error,
            {
                if value.is_finite() {
                    Ok(SwiftDate(value))
                } else {
                    Err(E::custom("date must be finite"))
                }
            }

            fn visit_i64<E>(self, value: i64) -> Result<Self::Value, E>
            where
                E: de::Error,
            {
                Ok(SwiftDate(value as f64))
            }

            fn visit_u64<E>(self, value: u64) -> Result<Self::Value, E>
            where
                E: de::Error,
            {
                Ok(SwiftDate(value as f64))
            }

            fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
            where
                E: de::Error,
            {
                if let Ok(seconds) = value.parse::<f64>() {
                    return self.visit_f64(seconds);
                }
                let date = DateTime::parse_from_rfc3339(value)
                    .map_err(|_| E::custom("date is not valid RFC 3339"))?;
                let unix = date.timestamp() as f64
                    + f64::from(date.timestamp_subsec_nanos()) / 1_000_000_000.0;
                Ok(SwiftDate::from_unix_seconds(unix))
            }
        }

        deserializer.deserialize_any(SwiftDateVisitor)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaFolder {
    #[serde(default = "new_id")]
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_folder_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MediaSource {
    External {
        #[serde(rename = "absolutePath")]
        absolute_path: String,
    },
    Project {
        #[serde(rename = "relativePath")]
        relative_path: String,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct UpscaleSettings {
    pub selections: BTreeMap<String, String>,
    pub numbers: BTreeMap<String, f64>,
    pub toggles: BTreeMap<String, bool>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaImportInput {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<SwiftDate>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerationInput {
    pub prompt: String,
    pub model: String,
    pub duration: i32,
    pub aspect_ratio: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolution: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upscale_settings: Option<UpscaleSettings>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upscale_source_width: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upscale_source_height: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upscale_source_fps: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quality: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_urls: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub num_images: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub voice: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lyrics: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub style_instructions: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub instrumental: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_language: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub multilingual: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio_input: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generate_audio: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub draft: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uses_source_video: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reference_image_urls: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reference_video_urls: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reference_audio_urls: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_url_asset_ids: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reference_image_asset_ids: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reference_video_asset_ids: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reference_audio_asset_ids: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<SwiftDate>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub backend_job_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_index: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result_urls: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaManifestEntry {
    pub id: String,
    pub name: String,
    #[serde(rename = "type")]
    pub media_type: ClipType,
    pub source: MediaSource,
    pub duration: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generation_input: Option<GenerationInput>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_width: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_height: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_fps: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub has_audio: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cached_remote_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cached_remote_url_expires_at: Option<SwiftDate>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generation_status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub import_input: Option<MediaImportInput>,
}

fn manifest_version_one() -> i32 {
    1
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaManifest {
    #[serde(default = "manifest_version_one")]
    pub version: i32,
    #[serde(default)]
    pub entries: Vec<MediaManifestEntry>,
    #[serde(default)]
    pub folders: Vec<MediaFolder>,
}

impl Default for MediaManifest {
    fn default() -> Self {
        Self {
            version: 2,
            entries: Vec::new(),
            folders: Vec::new(),
        }
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
    fn project_file_decodes_a_legacy_bare_timeline() {
        let timeline = Timeline {
            fps: 24,
            tracks: vec![Track {
                clips: vec![clip("clip", 0, 10)],
                ..Track::new(ClipType::Video)
            }],
            ..Timeline::default()
        };
        let bytes = serde_json::to_vec(&timeline).unwrap();
        let project = ProjectFile::decode_json(&bytes).unwrap();
        assert_eq!(project.timelines, vec![timeline.clone()]);
        assert_eq!(
            project.active_timeline_id.as_deref(),
            Some(timeline.id.as_str())
        );
    }

    #[test]
    fn malformed_project_file_is_not_misread_as_a_legacy_timeline() {
        let bytes = br#"{"timelines":[],"activeTimelineId":7}"#;
        assert!(ProjectFile::decode_json(bytes).is_err());
    }

    #[test]
    fn legacy_clip_and_track_fields_receive_swift_defaults() {
        let track: Track = serde_json::from_str(r#"{"id":"t","type":"video","clips":[]}"#).unwrap();
        assert!(!track.muted);
        assert!(!track.hidden);
        assert!(track.sync_locked);

        let clip: Clip =
            serde_json::from_str(r#"{"id":"c","mediaRef":"m","startFrame":0,"durationFrames":30}"#)
                .unwrap();
        assert_eq!(clip.speed, 1.0);
        assert_eq!(clip.volume, 1.0);
        assert_eq!(clip.opacity, 1.0);
        assert_eq!(clip.fade_in_interpolation, Interpolation::Linear);
        assert_eq!(clip.transform, Transform::default());
    }

    #[test]
    fn malformed_legacy_defaulted_fields_do_not_break_decode() {
        let clip: Clip = serde_json::from_str(
            r#"{
                "id":7,
                "mediaRef":"m",
                "startFrame":0,
                "durationFrames":30,
                "speed":"old",
                "opacity":null,
                "fadeInInterpolation":"unknown"
            }"#,
        )
        .unwrap();
        assert!(!clip.id.is_empty());
        assert_eq!(clip.speed, 1.0);
        assert_eq!(clip.opacity, 1.0);
        assert_eq!(clip.fade_in_interpolation, Interpolation::Linear);

        let style: TextStyle =
            serde_json::from_str(r#"{"fontName":"Helvetica","fontSize":"old","tracking":8}"#)
                .unwrap();
        assert_eq!(style.font_size, 96.0);
        assert_eq!(style.tracking, 8.0);
    }

    #[test]
    fn transform_accepts_legacy_top_left_keys() {
        let transform: Transform =
            serde_json::from_str(r#"{"x":0.1,"y":0.2,"width":0.4,"height":0.3}"#).unwrap();
        assert!((transform.center_x - 0.0).abs() < 1e-12);
        assert!((transform.center_y - 0.0).abs() < 1e-12);
    }

    #[test]
    fn text_style_missing_fields_use_current_defaults() {
        let style: TextStyle =
            serde_json::from_str(r#"{"fontName":"Helvetica-Bold","border":{"enabled":true}}"#)
                .unwrap();
        assert_eq!(style.font_scale, 1.0);
        assert!(style.is_bold);
        assert!(style.border.enabled);
        assert_eq!(style.border.width, 4.0);
    }

    #[test]
    fn media_source_uses_swift_associated_enum_shape() {
        let source = MediaSource::External {
            absolute_path: "/tmp/a.mov".to_owned(),
        };
        assert_eq!(
            serde_json::to_value(&source).unwrap(),
            serde_json::json!({"external":{"absolutePath":"/tmp/a.mov"}})
        );
        assert_eq!(
            serde_json::from_value::<MediaSource>(
                serde_json::json!({"project":{"relativePath":"media/a.mov"}})
            )
            .unwrap(),
            MediaSource::Project {
                relative_path: "media/a.mov".to_owned()
            }
        );
    }

    #[test]
    fn swift_dates_encode_reference_seconds_and_tolerate_iso_dates() {
        let reference: SwiftDate = serde_json::from_str("0").unwrap();
        assert_eq!(reference.unix_seconds(), 978_307_200.0);
        assert_eq!(serde_json::to_string(&reference).unwrap(), "0.0");

        let iso: SwiftDate = serde_json::from_str(r#""2001-01-01T00:00:00Z""#).unwrap();
        assert_eq!(iso.0, 0.0);
    }

    #[test]
    fn complete_clip_model_round_trips() {
        let mut value = clip("clip", 100, 80);
        value.media_type = ClipType::Text;
        value.source_clip_type = ClipType::Text;
        value.text_content = Some("Hello".to_owned());
        value.text_style = Some(TextStyle::default());
        value.text_animation = Some(TextAnimation {
            preset: TextAnimationPreset::WordPop,
            ..TextAnimation::default()
        });
        value.opacity_track = Some(KeyframeTrack {
            keyframes: vec![Keyframe::new(5, 0.5)],
        });
        value.effects = Some(vec![Effect::new("color.invert")]);
        value.blend_mode = Some(BlendMode::Overlay);
        let bytes = serde_json::to_vec(&value).unwrap();
        assert_eq!(serde_json::from_slice::<Clip>(&bytes).unwrap(), value);
    }

    #[test]
    fn project_metadata_round_trips_speakers_folders_and_multicam() {
        let member = MulticamMember {
            id: "member".to_owned(),
            media_ref: "media".to_owned(),
            kind: MulticamMemberKind::Both,
            angle_label: "host".to_owned(),
            sync: MulticamSyncMap {
                offset_seconds: 1.5,
                confidence: 0.91,
                locked: false,
            },
        };
        let project = ProjectFile {
            timelines: vec![Timeline {
                id: "timeline".to_owned(),
                folder_id: Some("folder".to_owned()),
                ..Timeline::default()
            }],
            active_timeline_id: Some("timeline".to_owned()),
            open_timeline_ids: Some(vec!["timeline".to_owned()]),
            view_states: Some(BTreeMap::from([(
                "timeline".to_owned(),
                TimelineViewState {
                    playhead_frame: 42,
                    zoom_scale: 7.0,
                    scroll_offset_x: 300.0,
                },
            )])),
            speakers: Some(vec![SpeakerRegistryEntry {
                id: 1,
                name: "Speaker 1".to_owned(),
                color: vec![0.0, 0.5, 1.0, 1.0],
                centroid: vec![0.1, 0.2],
            }]),
            multicam_groups: Some(vec![MulticamSource {
                id: "multicam".to_owned(),
                name: "Interview".to_owned(),
                members: vec![member],
                master_member_id: "member".to_owned(),
            }]),
        };
        let bytes = serde_json::to_vec(&project).unwrap();
        assert_eq!(ProjectFile::decode_json(&bytes).unwrap(), project);
    }

    #[test]
    fn media_manifest_round_trips_generation_and_swift_dates() {
        let json = serde_json::json!({
            "version": 2,
            "entries": [{
                "id": "generated",
                "name": "Generated",
                "type": "video",
                "source": {"project": {"relativePath": "media/generated.mp4"}},
                "duration": 8.0,
                "generationInput": {
                    "prompt": "A shot",
                    "model": "video-model",
                    "duration": 8,
                    "aspectRatio": "16:9",
                    "upscaleSettings": {
                        "selections": {"targetResolution": "4k"},
                        "numbers": {"strength": 0.5},
                        "toggles": {"grain": true}
                    },
                    "createdAt": 0.0,
                    "backendJobId": "job",
                    "resultURLs": ["https://example.invalid/result"]
                },
                "cachedRemoteURL": "https://example.invalid/cache",
                "cachedRemoteURLExpiresAt": 1.0,
                "generationStatus": "generating"
            }],
            "folders": [{"id": "folder", "name": "Generated"}]
        });
        let manifest: MediaManifest = serde_json::from_value(json).unwrap();
        let bytes = serde_json::to_vec(&manifest).unwrap();
        assert_eq!(
            serde_json::from_slice::<MediaManifest>(&bytes).unwrap(),
            manifest
        );
        assert_eq!(
            manifest.entries[0]
                .generation_input
                .as_ref()
                .unwrap()
                .created_at,
            Some(SwiftDate(0.0))
        );
    }

    #[test]
    fn keyframe_track_is_sorted_and_last_write_wins() {
        let mut track = KeyframeTrack::default();
        track.upsert(Keyframe::new(20, 2.0));
        track.upsert(Keyframe::new(5, 0.5));
        track.upsert(Keyframe::new(20, 9.0));
        assert_eq!(
            track
                .keyframes
                .iter()
                .map(|keyframe| keyframe.frame)
                .collect::<Vec<_>>(),
            vec![5, 20]
        );
        assert_eq!(track.keyframes[1].value, 9.0);
    }

    #[test]
    fn keyframe_sampling_honors_left_interpolation() {
        let track = KeyframeTrack {
            keyframes: vec![
                Keyframe {
                    frame: 0,
                    value: 0.0,
                    interpolation_out: Interpolation::Hold,
                },
                Keyframe::new(10, 10.0),
            ],
        };
        assert_eq!(track.sample(9, 42.0), 0.0);
        assert_eq!(track.sample(10, 42.0), 10.0);
    }

    #[test]
    fn clip_math_uses_half_open_ranges_and_fades() {
        let mut value = clip("clip", 50, 30);
        value.fade_in_frames = 10;
        assert!(value.contains(50));
        assert!(value.contains(79));
        assert!(!value.contains(80));
        assert_eq!(value.fade_multiplier(50), 0.0);
        assert_eq!(value.fade_multiplier(55), 0.5);
        assert_eq!(value.fade_multiplier(60), 1.0);
    }
}
