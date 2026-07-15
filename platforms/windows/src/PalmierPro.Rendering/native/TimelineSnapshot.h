#pragma once

#include "Keyframe.h"

#include <cstdint>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

// C++ mirror of the timeline-snapshot-v1(.1) JSON contract — see
// platforms/windows/docs/timeline-snapshot-v1.md (§11 for the v1.1 extension). Parsed by
// TimelineSnapshotParser (simdjson). Field names/shapes match the doc exactly.
//
// v1.1: keyframe envelopes (`{ "value": ..., "keyframes": [...] }`) may now carry a
// populated `keyframes` array — clip-relative frames, sampled via SampleKeyframeTrack
// (Keyframe.h), matching KeyframeTrack<T>.Sample (PalmierPro.Core/Models/Keyframe.cs /
// Keyframe.swift) exactly. Each SnapshotClip also carries an ordered `effects` list
// mirroring the Core `Effect`/`EffectParam` model verbatim.

struct SnapshotTransform
{
    double centerX = 0.5;
    double centerY = 0.5;
    double width = 1.0;
    double height = 1.0;
    double rotationDegrees = 0.0;
    bool flipHorizontal = false;
    bool flipVertical = false;
};

struct SnapshotCrop
{
    double left = 0.0;
    double top = 0.0;
    double right = 0.0;
    double bottom = 0.0;

    bool IsIdentity() const { return left == 0.0 && top == 0.0 && right == 0.0 && bottom == 0.0; }
    double VisibleWidthFraction() const { double v = 1.0 - left - right; return v < 0.0 ? 0.0 : v; }
    double VisibleHeightFraction() const { double v = 1.0 - top - bottom; return v < 0.0 ? 0.0 : v; }
};

enum class SnapshotClipType
{
    Video,
    Audio,
    Image,
};

// One `params[name]` entry of a v1.1 SnapshotEffect — mirrors Core's EffectParam
// (value/string/keyframes) verbatim, but the wire key is "keyframes" here (not Core's
// project-file "track") — see docs/timeline-snapshot-v1.md §11.
struct SnapshotEffectParam
{
    std::optional<double> value;
    std::optional<std::string> stringValue;
    std::vector<SnapshotKeyframe<double>> keyframes; // clip-relative frames

    double Resolve(int64_t clipRelativeFrame, double defaultValue) const
    {
        double base = value.value_or(defaultValue);
        if (keyframes.empty())
        {
            return base;
        }
        return SampleKeyframeTrack(keyframes, clipRelativeFrame, base, InterpolateDouble);
    }
};

// One entry of a v1.1 SnapshotClip's ordered `effects` list — mirrors Core's `Effect`
// (type/enabled/params) verbatim.
struct SnapshotEffect
{
    std::string type;
    bool enabled = true;
    std::unordered_map<std::string, SnapshotEffectParam> params;

    const SnapshotEffectParam* Param(const std::string& key) const
    {
        auto it = params.find(key);
        return it == params.end() ? nullptr : &it->second;
    }
};

// Componentwise-linear interpolation for SnapshotCrop, mirroring Crop.keyframeInterpolate
// (Keyframe.swift) / KeyframeInterpolation.Crop (Keyframe.cs) — the SAME (possibly
// smooth-stepped) `t` is applied to all four edges.
inline SnapshotCrop InterpolateCrop(const SnapshotCrop& a, const SnapshotCrop& b, double t)
{
    SnapshotCrop out;
    out.left = InterpolateDouble(a.left, b.left, t);
    out.top = InterpolateDouble(a.top, b.top, t);
    out.right = InterpolateDouble(a.right, b.right, t);
    out.bottom = InterpolateDouble(a.bottom, b.bottom, t);
    return out;
}

// Componentwise-linear interpolation for a merged SnapshotTransform keyframe. There is no
// direct Swift/C# equivalent (the Mac tracks position/scale/rotation as three SEPARATE
// KeyframeTrack<AnimPair>/KeyframeTrack<Double> properties on Clip, never one compound
// "transform" track) — the Windows snapshot schema merges them into one combined envelope
// for wire simplicity (see docs/timeline-snapshot-v1.md §11 and
// TimelineSnapshotBuilder.BuildTransformKeyframes on the C# side, which samples each
// underlying Swift-equivalent track independently and correctly AT each merged anchor
// frame — only the interpolation curve shape BETWEEN two merged anchors is an
// approximation of the true independent per-property curves). Flip flags are not
// interpolatable; they step at the midpoint of the segment (arbitrary but deterministic —
// flips are not expected to be keyframed in practice).
inline SnapshotTransform InterpolateTransform(const SnapshotTransform& a, const SnapshotTransform& b, double t)
{
    SnapshotTransform out;
    out.centerX = InterpolateDouble(a.centerX, b.centerX, t);
    out.centerY = InterpolateDouble(a.centerY, b.centerY, t);
    out.width = InterpolateDouble(a.width, b.width, t);
    out.height = InterpolateDouble(a.height, b.height, t);
    out.rotationDegrees = InterpolateDouble(a.rotationDegrees, b.rotationDegrees, t);
    out.flipHorizontal = t < 0.5 ? a.flipHorizontal : b.flipHorizontal;
    out.flipVertical = t < 0.5 ? a.flipVertical : b.flipVertical;
    return out;
}

struct SnapshotClip
{
    std::string id;
    SnapshotClipType type = SnapshotClipType::Video;
    int64_t startFrame = 0;
    int64_t durationFrames = 0;
    int64_t trimStartFrame = 0;
    double speed = 1.0;
    std::string mediaPath;
    std::optional<bool> hasAlphaHint;
    std::optional<std::string> blendMode; // raw BlendMode value; unset/"normal" == source-over
    double opacity = 1.0;
    SnapshotTransform transform;
    SnapshotCrop crop;
    double volumeGain = 1.0; // unused by the video compositor; consumed by AudioMixer (E4.5)

    // Audio mix fields (docs/audio-playback-v1.md §1). Unused by the video compositor. `volume.gain`
    // above already folds Clip.volume with any nest carriers' static volume (§4); volumeKeyframes is
    // the dB keyframe track (empty == static, sampled 0 dB fallback == unity), fade* the head/tail ramp.
    int64_t fadeInFrames = 0;
    int64_t fadeOutFrames = 0;
    SnapshotInterpolation fadeInInterpolation = SnapshotInterpolation::Linear;
    SnapshotInterpolation fadeOutInterpolation = SnapshotInterpolation::Linear;
    std::vector<SnapshotKeyframe<double>> volumeKeyframes; // clip-relative frames, dB values

    // v1.1: populated keyframe envelopes (clip-relative frames) — empty when the clip's
    // corresponding property is static (the v1 behavior). See docs/timeline-snapshot-v1.md §11.
    std::vector<SnapshotKeyframe<double>> opacityKeyframes;
    std::vector<SnapshotKeyframe<SnapshotCrop>> cropKeyframes;
    std::vector<SnapshotKeyframe<SnapshotTransform>> transformKeyframes;

    // v1.1: ordered effect chain — mirrors Clip.Effects (Core) verbatim.
    std::vector<SnapshotEffect> effects;

    int64_t EndFrameExclusive() const { return startFrame + durationFrames; }
    bool ContainsFrame(int64_t frame) const { return frame >= startFrame && frame < EndFrameExclusive(); }
    bool IsNormalBlend() const { return !blendMode.has_value() || *blendMode == "normal"; }

    // clipRelativeFrame = timelineFrame - startFrame (Keyframe.swift's `toOffset`).
    double OpacityAt(int64_t clipRelativeFrame) const
    {
        return opacityKeyframes.empty()
            ? opacity
            : SampleKeyframeTrack(opacityKeyframes, clipRelativeFrame, opacity, InterpolateDouble);
    }
    SnapshotCrop CropAt(int64_t clipRelativeFrame) const
    {
        return cropKeyframes.empty()
            ? crop
            : SampleKeyframeTrack(cropKeyframes, clipRelativeFrame, crop, InterpolateCrop);
    }
    SnapshotTransform TransformAt(int64_t clipRelativeFrame) const
    {
        return transformKeyframes.empty()
            ? transform
            : SampleKeyframeTrack(transformKeyframes, clipRelativeFrame, transform, InterpolateTransform);
    }
};

// --- v1.2: text clips (docs/timeline-snapshot-v1.md §12) ---------------------------------
//
// A text clip is NOT a SnapshotClip and never lives in SnapshotTrack.clips — it has no
// mediaPath (§12.2) and is rasterized at render time from font/content (TextRenderer.*),
// not decoded from a file. It rides on the SnapshotTrack whose EmitVideoLane produced it,
// inheriting that track's paint-order position (§12.2) exactly. Field set mirrors what
// Compositing/TextFrameRenderer.swift (TextFrameRenderer.image) + Compositing/FrameRenderer.swift
// (composedTextLayer) actually read off a `.text` Clip — see §12.3.

struct SnapshotRgba
{
    double r = 1.0;
    double g = 1.0;
    double b = 1.0;
    double a = 1.0;
};

// Mirrors Models/TextStyle.swift field-for-field (§12.4). Font resolution against the bundled
// DirectWrite collection is a render-time concern (FontRegistry); this carries the stored name
// verbatim, Helvetica-Bold default included.
struct SnapshotTextStyle
{
    std::string fontName = "Helvetica-Bold"; // Models/TextStyle.swift:8
    double fontSize = 96.0;
    double fontScale = 1.0;
    bool isBold = true;
    bool isItalic = false;
    SnapshotRgba color;                       // default white (RGBA())
    std::string alignment = "center";         // TextStyle.Alignment raw value: left|center|right
    bool shadowEnabled = true;
    SnapshotRgba shadowColor{0.0, 0.0, 0.0, 0.6};
    double shadowOffsetX = 0.0;
    double shadowOffsetY = -2.0;
    double shadowBlur = 6.0;
    bool backgroundEnabled = false;
    SnapshotRgba backgroundColor{0.0, 0.0, 0.0, 0.6};
    bool borderEnabled = false;
    SnapshotRgba borderColor{0.0, 0.0, 0.0, 1.0};
};

// Mirrors Models/TextAnimation.swift (§12.5). Per-frame evaluation is a pure function of these
// fields + wordTimings (TextAnimator.swift) — nothing precomputed on the C# side.
struct SnapshotTextAnimation
{
    std::string preset = "none"; // TextAnimation.Preset raw value
    int64_t perWordFrames = 6;
    std::optional<SnapshotRgba> highlight; // null -> TextAnimation.defaultHighlight at render time
};

struct SnapshotWordTiming
{
    std::string text;
    int64_t startFrame = 0; // clip-relative (TextFrameRenderer.tokenTimings compares against `rel`)
    int64_t endFrame = 0;
};

struct SnapshotTextClip
{
    std::string id;
    int64_t startFrame = 0;
    int64_t durationFrames = 0;
    std::string content;
    double opacity = 1.0;
    std::vector<SnapshotKeyframe<double>> opacityKeyframes; // clip-relative, same as SnapshotClip
    std::optional<std::string> blendMode; // unset/"normal" == source-over
    SnapshotTransform transform;          // flat (always static — §12.3), text box + anchor
    SnapshotTextStyle style;
    SnapshotTextAnimation animation;
    std::vector<SnapshotWordTiming> wordTimings;
    std::vector<SnapshotEffect> effects;  // §12.3, same convention as SnapshotClip.effects

    int64_t EndFrameExclusive() const { return startFrame + durationFrames; }
    bool ContainsFrame(int64_t frame) const { return frame >= startFrame && frame < EndFrameExclusive(); }
    bool IsNormalBlend() const { return !blendMode.has_value() || *blendMode == "normal"; }

    // clip.opacityAt(frame:) — composedTextLayer's one per-frame-sampled property for text.
    double OpacityAt(int64_t clipRelativeFrame) const
    {
        return opacityKeyframes.empty()
            ? opacity
            : SampleKeyframeTrack(opacityKeyframes, clipRelativeFrame, opacity, InterpolateDouble);
    }
};

enum class SnapshotTrackType
{
    Video,
    Audio,
};

struct SnapshotTrack
{
    std::string id;
    SnapshotTrackType type = SnapshotTrackType::Video;
    bool muted = false;
    std::vector<SnapshotClip> clips;         // ordered by startFrame, non-overlapping
    std::vector<SnapshotTextClip> textClips; // v1.2 — omitted-when-empty on the wire (§12.2)
};

// tracks[] is already in paint order (index 0 = bottom/first-painted, last = top/
// last-painted) — see docs/timeline-snapshot-v1.md §2. The native compositor walks it
// forward with no reversal.
struct TimelineSnapshot
{
    int32_t version = 1;
    // Absent in JSON -> 0 (v1). 1 = v1.1 (populated keyframes + effects[] — see §11). 2 = v1.2
    // (per-track `textClips[]` — see §12; parsed here as of E4, rendered via TextRenderer).
    // Native never rejects on this field: an absent/0/unrecognized minorVersion just means every
    // clip's keyframe vectors/effects list are empty and each track's textClips list is empty,
    // which OpacityAt/CropAt/TransformAt/effects/the text pass already treat identically to the v1
    // static-only behavior. Text parsing keys off the presence of the `textClips` array itself, not
    // this field.
    int32_t minorVersion = 0;
    int32_t fpsNumerator = 30;
    int32_t fpsDenominator = 1;
    int32_t outputWidth = 1920;
    int32_t outputHeight = 1080;
    std::vector<SnapshotTrack> tracks;

    double Fps() const { return fpsDenominator != 0 ? static_cast<double>(fpsNumerator) / fpsDenominator : 30.0; }
};
