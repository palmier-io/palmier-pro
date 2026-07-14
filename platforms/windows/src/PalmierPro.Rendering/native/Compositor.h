#pragma once

#include "TimelineSnapshot.h"

#include <atomic>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

// Per-frame multi-track compositor. Mirrors Sources/PalmierPro/Compositing/FrameRenderer.swift
// and Sources/PalmierPro/Preview/CompositionBuilder.swift's affineTransform — see the
// comments on Compose() and BuildClipAffine() for exactly what's mirrored and what's a
// documented, deliberate simplification for this pass.
//
// COLOR PIPELINE (plan's "Color pipeline" section, non-color-managed to match the Mac's
// disabled-color-management CIContext): internal accumulation happens in gamma-encoded,
// premultiplied fp16 (BGRA Half) — no linearization anywhere in this file. Ingest from an
// 8-bit BGRA decode buffer (already matrix/range-converted by MediaSource's sws_scale
// path) is a straight bit-depth widen, nothing more. The final accumulator is converted
// back to 8-bit BGRA only at the very end, for the existing 8-bit sinks (PE_FrameBuffer /
// WicPngWriter / D3D11Presenter::PresentBgra) — that narrowing is lossless enough for
// preview/scrub (export's real GPU NV12 path is separate, later work) and involves no
// gamma transform either.
//
// COORDINATE CONVENTION: this compositor works entirely in a top-left-origin, y-down
// pixel space (ordinary raster/memory order) for both source and destination. That is
// deliberately the *same* space FrameRenderer.applyClipPipeline's transform math
// ultimately operates in once CoreImage's bottom-left-origin round-trip
// (`flipY(srcHeight)...flipY(renderSize.height)`) is worked through algebraically: the
// two flips exactly cancel CoreImage's y-up convention, leaving `CompositionBuilder.
// affineTransform`'s scale/translate/rotate acting directly on top-left-origin, y-down
// coordinates — see BuildClipAffine()'s comment for the transform itself. Concretely,
// this means Transform.rotation's "positive = clockwise" doc comment (Timeline.swift:491)
// can be implemented with the textbook counterclockwise-in-y-up rotation matrix applied
// unmodified to our y-down coordinates (which visually IS clockwise in a y-down space) —
// no extra axis flip needed anywhere in this file.
//
// OPACITY FADE (matches FrameRenderer, not the "conventional" premultiplied fade):
// FrameRenderer.applyClipPipeline fades a normal-blend layer's opacity by scaling *only*
// the stored alpha channel of an already-premultiplied CIImage via a `CIColorMatrix` with
// `inputAVector = (0,0,0,alpha)` (FrameRenderer.swift ~264-271), leaving the premultiplied
// RGB channels untouched. This is deliberately reproduced bit-for-bit here in
// SourceOverAccumulate (premultiply RGB by the source's own alpha only; fade only the
// alpha channel by clipAlpha) rather than the more "obviously correct" premultiplied fade
// that scales both RGB and alpha by opacity — the two are NOT equivalent for a partially-
// transparent clip over non-black content (e.g. red@0.5 over opaque blue: this pipeline's
// straight-alpha result is (255,0,128), the "scale both" result is (128,0,128) — a 127-level
// difference in the red channel). An earlier pass here implemented the "scale both" version
// on the theory the two were indistinguishable without a live CoreImage runtime to check
// against; that theory only holds over an *opaque black* base (where dst RGB is already
// zero, so scaling src RGB by opacity vs. not is invisible) — it does not hold in general,
// and was wrong. Golden fixtures sourced from the Mac will only match if this is bit-exact.
//
// NOT MIRRORED (out of v1 schema scope, not merely skipped): per-clip Effect chains
// (§5 of the snapshot contract has no `effects` field — E3), any AVFoundation
// `preferredTransform` / bitstream rotation-metadata handling (MediaSource decodes
// frames in their raw bitstream orientation; a rotated-by-metadata source will render
// sideways until a Windows equivalent lands), and non-"normal" BlendMode values (see
// ApplyBlendMode below — the dispatch seam for E3's Porter-Duff set).

// One decoded source frame, straight (non-premultiplied) alpha, 8-bit BGRA — the shape
// MediaSource::DecodeFrameAt*/WicImageReader both already produce.
struct DecodedSourceFrame
{
    const uint8_t* bgra = nullptr;
    int32_t width = 0;
    int32_t height = 0;
    int32_t strideBytes = 0;
};

// Supplied by TimelineSession: given a clip and the source-time (seconds) to sample,
// decode (or fetch from cache) that clip's frame. Returns false (and leaves outFrame
// untouched) if decode failed or was cancelled — Compositor treats that clip as absent
// for this frame rather than failing the whole composite, matching the Mac's
// per-clip-tolerant behavior (an unreadable clip doesn't blank the rest of the frame).
using ClipFrameProvider = std::function<bool(const SnapshotClip& clip, double sourceSeconds, DecodedSourceFrame& outFrame)>;

struct ComposeResult
{
    std::vector<uint8_t> bgra; // 8-bit, straight/opaque BGRA, width*height*4, row-major
    int32_t width = 0;
    int32_t height = 0;
    int32_t strideBytes = 0;
};

namespace Compositor
{
    // Timeline-frame -> source-seconds retiming, exactly as documented in the plan's
    // "Render graph" section: `trimStart + (frame - startFrame) * speed`, evaluated in
    // timeline-fps units (matches Timeline.swift:320's `timelineFrame(sourceSeconds:fps:)`
    // inverse), then divided by timelineFps to get the seconds value MediaSource expects.
    double SourceSeconds(const SnapshotClip& clip, int64_t timelineFrame, double timelineFps);

    // Renders `frame` of `snapshot` into a BGRA8 buffer sized snapshot.outputWidth x
    // outputHeight. `cancelFlag` (may be null) is checked between clips/tracks — if it
    // becomes non-zero mid-composite, returns false with outError == "cancelled" (used by
    // TimelineSession's render thread to abort a stale interactive-scrub compose as soon
    // as a newer request supersedes it).
    bool Compose(
        const TimelineSnapshot& snapshot,
        int64_t frame,
        const ClipFrameProvider& provider,
        const std::atomic<int32_t>* cancelFlag,
        ComposeResult& outResult,
        std::string& outError);
}
