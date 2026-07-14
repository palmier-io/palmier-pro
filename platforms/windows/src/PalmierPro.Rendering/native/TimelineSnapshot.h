#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

// C++ mirror of the timeline-snapshot-v1 JSON contract — see
// platforms/windows/docs/timeline-snapshot-v1.md. Parsed by TimelineSnapshotParser
// (simdjson). Field names/shapes match the doc exactly; v1's keyframe envelopes
// (`{ "value": ..., "keyframes": null }`) are always static in this schema version, so
// only the resolved `value` is carried here — see TimelineSnapshotParser.cpp for the
// (documented, deliberate) v1 limitation of dropping a non-null `keyframes` silently.

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

    int64_t EndFrameExclusive() const { return startFrame + durationFrames; }
    bool ContainsFrame(int64_t frame) const { return frame >= startFrame && frame < EndFrameExclusive(); }
    bool IsNormalBlend() const { return !blendMode.has_value() || *blendMode == "normal"; }
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
    int32_t fpsNumerator = 30;
    int32_t fpsDenominator = 1;
    int32_t outputWidth = 1920;
    int32_t outputHeight = 1080;
    std::vector<SnapshotTrack> tracks;

    double Fps() const { return fpsDenominator != 0 ? static_cast<double>(fpsNumerator) / fpsDenominator : 30.0; }
};
