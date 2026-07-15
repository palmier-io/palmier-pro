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
    double volumeGain = 1.0; // unused by the video compositor; carried for schema parity

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
    std::vector<SnapshotClip> clips; // ordered by startFrame, non-overlapping
};

// tracks[] is already in paint order (index 0 = bottom/first-painted, last = top/
// last-painted) — see docs/timeline-snapshot-v1.md §2. The native compositor walks it
// forward with no reversal.
struct TimelineSnapshot
{
    int32_t version = 1;
    // Absent in JSON -> 0 (v1). 1 = v1.1 (populated keyframes + effects[] — see §11).
    // Native never rejects on this field: an absent/0 minorVersion just means every clip's
    // keyframe vectors/effects list are empty, which OpacityAt/CropAt/TransformAt/effects
    // already treat identically to the v1 static-only behavior.
    int32_t minorVersion = 0;
    int32_t fpsNumerator = 30;
    int32_t fpsDenominator = 1;
    int32_t outputWidth = 1920;
    int32_t outputHeight = 1080;
    std::vector<SnapshotTrack> tracks;

    double Fps() const { return fpsDenominator != 0 ? static_cast<double>(fpsNumerator) / fpsDenominator : 30.0; }
};
