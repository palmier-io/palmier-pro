#pragma once

#include <cstdint>
#include <string>
#include <vector>

// C++ port of KeyframeTrack<T>.Sample (PalmierPro.Core/Models/Keyframe.cs), which itself
// mirrors Keyframe.swift's `KeyframeTrack.sample(at:fallback:)` exactly: empty -> fallback,
// single keyframe -> that value, before-first/after-last -> clamp to the end value, else
// hold/linear/smooth between the bracketing pair. `frame` is always CLIP-RELATIVE (the
// snapshot's keyframe envelopes carry clip-relative frames — see docs/timeline-snapshot-v1.md
// v1.1 section), matching the Swift storage convention (Keyframe.swift's `toOffset`).

enum class SnapshotInterpolation
{
    Linear,
    Hold,
    Smooth,
};

inline SnapshotInterpolation ParseInterpolation(const std::string& s)
{
    if (s == "hold") return SnapshotInterpolation::Hold;
    if (s == "smooth") return SnapshotInterpolation::Smooth;
    return SnapshotInterpolation::Linear; // default + unrecognized value both fall back to linear
}

inline double SmoothStep(double t) { return t * t * (3.0 - 2.0 * t); }

template <typename T>
struct SnapshotKeyframe
{
    int64_t frame = 0; // clip-relative
    T value{};
    SnapshotInterpolation interpolation = SnapshotInterpolation::Linear;
};

// `interpolate(a, b, t)` mirrors Swift's KeyframeInterpolatable.keyframeInterpolate / C#'s
// KeyframeInterpolation delegates.
template <typename T, typename Interp>
T SampleKeyframeTrack(const std::vector<SnapshotKeyframe<T>>& kfs, int64_t frame, const T& fallback, Interp interpolate)
{
    if (kfs.empty())
    {
        return fallback;
    }
    if (kfs.size() == 1)
    {
        return kfs[0].value;
    }
    if (frame <= kfs.front().frame)
    {
        return kfs.front().value;
    }
    if (frame >= kfs.back().frame)
    {
        return kfs.back().value;
    }

    size_t bIdx = kfs.size();
    for (size_t i = 0; i < kfs.size(); ++i)
    {
        if (kfs[i].frame > frame)
        {
            bIdx = i;
            break;
        }
    }
    if (bIdx == 0 || bIdx >= kfs.size())
    {
        return kfs.back().value; // unreachable given the guards above; defensive fallback
    }

    const SnapshotKeyframe<T>& a = kfs[bIdx - 1];
    const SnapshotKeyframe<T>& b = kfs[bIdx];
    double raw = (b.frame == a.frame)
        ? 0.0
        : static_cast<double>(frame - a.frame) / static_cast<double>(b.frame - a.frame);

    switch (a.interpolation)
    {
        case SnapshotInterpolation::Hold:
            return a.value;
        case SnapshotInterpolation::Smooth:
            return interpolate(a.value, b.value, SmoothStep(raw));
        case SnapshotInterpolation::Linear:
        default:
            return interpolate(a.value, b.value, raw);
    }
}

inline double InterpolateDouble(double a, double b, double t) { return a + (b - a) * t; }
