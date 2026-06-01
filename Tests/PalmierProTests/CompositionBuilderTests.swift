import AVFoundation
import Testing
@testable import PalmierPro

@Suite("CompositionBuilder.smoothSubdivisions")
struct SmoothSubdivisionsTests {

    @Test func emptyWhenSpanIsZero() {
        #expect(CompositionBuilder.smoothSubdivisions(from: 10, to: 10).isEmpty)
    }

    @Test func emptyWhenSpanIsNegative() {
        // Defensive guard — caller computes b - a from arbitrary kf offsets.
        #expect(CompositionBuilder.smoothSubdivisions(from: 20, to: 10).isEmpty)
    }

    @Test func produces7InteriorPointsAtEvenSpacing() {
        // smoothSegments = 8, span = 80 → 7 interior offsets at 10, 20, ..., 70.
        let result = CompositionBuilder.smoothSubdivisions(from: 0, to: 80)
        #expect(result == [10, 20, 30, 40, 50, 60, 70])
    }

    @Test func interiorPointsAreShiftedByStart() {
        // span 80, start 100 → 110, 120, ..., 170.
        let result = CompositionBuilder.smoothSubdivisions(from: 100, to: 180)
        #expect(result == [110, 120, 130, 140, 150, 160, 170])
    }

    @Test func subdivisionCountIsAtMostSegmentsMinusOne() {
        // Tight spans collapse duplicates after dedupe — count is bounded but may be smaller.
        let result = CompositionBuilder.smoothSubdivisions(from: 0, to: 3)
        #expect(result.count <= CompositionBuilder.smoothSegments - 1)
    }

    @Test func returnsDistinctOffsetsInAscendingOrder() {
        // The function dedupes internally so callers don't have to.
        for (a, b) in [(0, 1), (0, 3), (100, 110), (0, 1000)] {
            let result = CompositionBuilder.smoothSubdivisions(from: a, to: b)
            #expect(Set(result).count == result.count, "duplicates in \(result) for span \(a)..\(b)")
            #expect(result == result.sorted(), "not ascending: \(result)")
        }
    }

    @Test func tightSpansCollapseDuplicateOffsets() {
        // span=1: 7 raw subdivisions round to {0, 1}. After dedupe → 2 distinct offsets.
        let result = CompositionBuilder.smoothSubdivisions(from: 0, to: 1)
        #expect(result == [0, 1])
    }
}

// MARK: - trackOps

private func cm(_ frame: Int) -> CMTime { CMTime(value: CMTimeValue(frame), timescale: 30) }

/// Build a Double KeyframeTrack from (frame, value, interp) tuples.
private func track(_ kfs: [(Int, Double, Interpolation)]) -> KeyframeTrack<Double> {
    var t = KeyframeTrack<Double>()
    for (frame, value, interp) in kfs {
        t.upsert(Keyframe(frame: frame, value: value, interpolationOut: interp))
    }
    return t
}

/// Run trackOps against a clip starting at frame 100 with the given duration.
private func runOps(
    track kfTrack: KeyframeTrack<Double>?,
    fallback: Double = 0,
    durationFrames: Int = 80
) -> [CompositionBuilder.TrackOp<Double>] {
    let clip = Fixtures.clip(start: 100, duration: durationFrames)
    return CompositionBuilder.trackOps(
        track: kfTrack,
        fallback: fallback,
        clip: clip,
        clipStart: cm(100),
        clipEnd: cm(100 + durationFrames),
        timescale: 30
    )
}

@Suite("CompositionBuilder.trackOps — fallbacks")
struct TrackOpsFallbackTests {

    @Test func nilTrackEmitsSingleStaticFallback() {
        let ops = runOps(track: nil, fallback: 0.5)
        #expect(ops.count == 1)
        if case let .setStatic(v, t) = ops[0] {
            #expect(v == 0.5)
            #expect(t == cm(100))
        } else {
            Issue.record("expected .setStatic")
        }
    }

    @Test func emptyTrackEmitsFallback() {
        // KeyframeTrack with no kfs reports isActive=false → fallback path.
        let ops = runOps(track: KeyframeTrack<Double>(), fallback: 0.7)
        #expect(ops.count == 1)
        if case let .setStatic(v, _) = ops[0] { #expect(v == 0.7) }
    }

    @Test func allKeyframesOutsideClipRangeEmitFallback() {
        // Keyframes with offsets > durationFrames (or < 0) get defensively filtered.
        let t = track([(-5, 0.1, .linear), (200, 0.9, .linear)]) // clip duration = 80
        let ops = runOps(track: t, fallback: 0.5)
        #expect(ops.count == 1)
        if case let .setStatic(v, _) = ops[0] { #expect(v == 0.5) }
    }
}

@Suite("CompositionBuilder.trackOps — single keyframe")
struct TrackOpsSingleKeyframeTests {

    @Test func keyframeAtClipStartEmitsOnlyTrailingStatic() {
        // firstT == clipStart, so no leading static. No segments. lastT < clipEnd → trailing static.
        let ops = runOps(track: track([(0, 0.9, .linear)]))
        #expect(ops.count == 1)
        if case let .setStatic(v, t) = ops[0] {
            #expect(v == 0.9)
            #expect(t == cm(100))
        }
    }

    @Test func keyframeInteriorEmitsLeadingAndTrailingStatic() {
        // firstT > clipStart → leading static. lastT < clipEnd → trailing static.
        let ops = runOps(track: track([(20, 0.4, .linear)]))
        #expect(ops.count == 2)
        if case let .setStatic(v, t) = ops[0] {
            #expect(v == 0.4) // leading holds the kf's value across the lead-in
            #expect(t == cm(100))
        }
        if case let .setStatic(v, t) = ops[1] {
            #expect(v == 0.4)
            #expect(t == cm(120)) // 100 + 20
        }
    }
}

@Suite("CompositionBuilder.trackOps — linear")
struct TrackOpsLinearTests {

    @Test func twoKeyframesSpanningWholeClipEmitOneRamp() {
        // kfs at 0 and 80; clip [100, 180). firstT == clipStart, lastT == clipEnd → no edge statics.
        let ops = runOps(track: track([(0, 0, .linear), (80, 1, .linear)]))
        #expect(ops.count == 1)
        guard case let .ramp(a, b, range) = ops[0] else {
            Issue.record("expected .ramp")
            return
        }
        #expect(a == 0)
        #expect(b == 1)
        #expect(range.start == cm(100))
        #expect(range.end == cm(180))
    }

    @Test func interiorLinearKeyframesGetLeadingAndTrailingStatics() {
        // kfs at 20 and 60: leading static at clipStart, one ramp, trailing static at kf2.
        let ops = runOps(track: track([(20, 0.2, .linear), (60, 0.8, .linear)]))
        #expect(ops.count == 3)
        if case let .setStatic(v, t) = ops[0] {
            #expect(v == 0.2)
            #expect(t == cm(100))
        }
        if case let .ramp(a, b, range) = ops[1] {
            #expect(a == 0.2)
            #expect(b == 0.8)
            #expect(range.start == cm(120))
            #expect(range.end == cm(160))
        }
        if case let .setStatic(v, t) = ops[2] {
            #expect(v == 0.8)
            #expect(t == cm(160))
        }
    }
}

@Suite("CompositionBuilder.trackOps — hold")
struct TrackOpsHoldTests {

    @Test func holdEmitsStaticAtSegmentStartNotRamp() {
        // Hold means: jump to a.value at aT, stay there until next kf.
        let ops = runOps(track: track([(0, 0.3, .hold), (40, 0.7, .linear)]))
        // Expect: setStatic(0.3) at clipStart (no leading because firstT == clipStart),
        //         setStatic(0.7) trailing at kf2.
        // ops[0]: hold static at aT (=clipStart). ops[1]: trailing static at bT.
        #expect(ops.count == 2)
        if case let .setStatic(v, t) = ops[0] {
            #expect(v == 0.3)
            #expect(t == cm(100))
        }
        if case let .setStatic(v, t) = ops[1] {
            #expect(v == 0.7)
            #expect(t == cm(140))
        }
        // Critically: no .ramp emitted between the two.
        let rampCount = ops.filter { if case .ramp = $0 { return true }; return false }.count
        #expect(rampCount == 0)
    }
}

@Suite("CompositionBuilder.trackOps — smooth")
struct TrackOpsSmoothTests {

    @Test func smoothEmitsOneRampPerSubdivision() {
        // smoothSegments=8 → 8 sub-ramps for a single smooth segment.
        let ops = runOps(track: track([(0, 0, .smooth), (80, 1, .linear)]))
        let ramps = ops.filter { if case .ramp = $0 { return true }; return false }
        #expect(ramps.count == 8)
    }

    @Test func smoothRampsStartAtKeyframeAValueAndEndAtKeyframeBValue() {
        let ops = runOps(track: track([(0, 0, .smooth), (80, 1, .linear)]))
        let ramps = ops.compactMap { op -> (Double, Double, CMTimeRange)? in
            if case let .ramp(a, b, r) = op { return (a, b, r) }
            return nil
        }
        #expect(ramps.first?.0 == 0)         // first sub-ramp begins at a.value
        #expect(ramps.last?.1 == 1)          // last sub-ramp ends at b.value
        #expect(ramps.first?.2.start == cm(100))
        #expect(ramps.last?.2.end == cm(180))
    }

    @Test func smoothSubRampsAreNonOverlappingAndChainContiguously() {
        let ops = runOps(track: track([(0, 0, .smooth), (80, 1, .linear)]))
        let ramps = ops.compactMap { op -> CMTimeRange? in
            if case let .ramp(_, _, r) = op { return r }
            return nil
        }
        // Adjacent ramps must share an edge: ramp[i].end == ramp[i+1].start.
        for i in 0..<(ramps.count - 1) {
            #expect(ramps[i].end == ramps[i + 1].start)
        }
    }
}

@Suite("CompositionBuilder.trackOps — additional shapes")
struct TrackOpsAdditionalShapeTests {

    @Test func threeKeyframesEmitTwoChainedRamps() {
        // kfs at 0, 40, 80 — span the whole clip; no edge statics; 2 chained ramps.
        let ops = runOps(track: track([
            (0, 0, .linear), (40, 0.5, .linear), (80, 1, .linear),
        ]))
        #expect(ops.count == 2)
        let ramps = ops.compactMap { op -> (Double, Double, CMTimeRange)? in
            if case let .ramp(a, b, r) = op { return (a, b, r) }
            return nil
        }
        #expect(ramps.count == 2)
        #expect(ramps[0].0 == 0)
        #expect(ramps[0].1 == 0.5)
        #expect(ramps[1].0 == 0.5)
        #expect(ramps[1].1 == 1)
        // Chain: ramp[0].end == ramp[1].start.
        #expect(ramps[0].2.end == ramps[1].2.start)
    }

    @Test func mixedInterpolationsPerSegment() {
        // Each segment's behavior comes from its LEFT kf's interpolationOut:
        //   [0]→[40] linear: 1 ramp
        //   [40]→[80] hold: 1 static at 40
        // Total: 2 ops, no leading/trailing edge statics (kfs span the clip).
        let ops = runOps(track: track([
            (0, 0, .linear), (40, 0.5, .hold), (80, 1, .linear),
        ]))
        #expect(ops.count == 2)
        // ops[0]: linear ramp 0→0.5
        if case let .ramp(a, b, _) = ops[0] {
            #expect(a == 0)
            #expect(b == 0.5)
        } else { Issue.record("expected .ramp at index 0") }
        // ops[1]: hold static at 0.5 (the right kf at 80 holds the previous value).
        if case let .setStatic(v, _) = ops[1] {
            #expect(v == 0.5)
        } else { Issue.record("expected .setStatic at index 1") }
    }

    @Test func singleKeyframeAtDurationFramesSuppressesTrailingStatic() {
        // kf at offset 80 (== durationFrames). firstT > clipStart → leading static.
        // lastT == clipEnd → `lastT < clipEnd` is false → no trailing static.
        let ops = runOps(track: track([(80, 0.9, .linear)]))
        #expect(ops.count == 1)
        if case let .setStatic(v, t) = ops[0] {
            #expect(v == 0.9)
            #expect(t == cm(100))
        }
    }

    @Test func defensiveFilterDropsOutOfRangeKfsButKeepsInRangeOnes() {
        // Three kfs: -5 (out), 40 (in), 200 (out). Only 40 survives.
        let ops = runOps(track: track([
            (-5, 0.1, .linear), (40, 0.5, .linear), (200, 0.9, .linear),
        ]))
        // Single in-range kf at interior offset → leading + trailing static.
        #expect(ops.count == 2)
        if case let .setStatic(v, _) = ops[0] { #expect(v == 0.5) }
        if case let .setStatic(v, t) = ops[1] {
            #expect(v == 0.5)
            #expect(t == cm(140))
        }
    }
}

// MARK: - build() validation guard

@Suite("CompositionBuilder.build — validation")
struct CompositionBuildValidationTests {

    private let renderSize = CGSize(width: 1920, height: 1080)
    /// resolveURL should never be invoked when the guard rejects the timeline.
    private let unreachable: @Sendable (String) -> URL? = { _ in
        Issue.record("resolveURL must not be called for invalid timelines")
        return nil
    }

    @Test func zeroFpsThrowsInvalidTimelineError() async {
        var timeline = Fixtures.timeline()
        timeline.fps = 0
        await #expect(throws: CompositionBuilder.InvalidTimelineError.self) {
            _ = try await CompositionBuilder.build(
                timeline: timeline, resolveURL: unreachable, renderSize: renderSize
            )
        }
    }

    @Test func zeroWidthThrowsInvalidTimelineError() async {
        var timeline = Fixtures.timeline()
        timeline.width = 0
        await #expect(throws: CompositionBuilder.InvalidTimelineError.self) {
            _ = try await CompositionBuilder.build(
                timeline: timeline, resolveURL: unreachable, renderSize: renderSize
            )
        }
    }

    @Test func zeroHeightThrowsInvalidTimelineError() async {
        var timeline = Fixtures.timeline()
        timeline.height = 0
        await #expect(throws: CompositionBuilder.InvalidTimelineError.self) {
            _ = try await CompositionBuilder.build(
                timeline: timeline, resolveURL: unreachable, renderSize: renderSize
            )
        }
    }
}

// MARK: - build() unreadable-asset resilience

@Suite("CompositionBuilder.build — unreadable assets")
struct CompositionBuildUnreadableAssetTests {

    private let renderSize = CGSize(width: 1920, height: 1080)

    /// Write non-media bytes to a temp .mov so AVFoundation throws "Cannot Open" on loadTracks.
    private func garbageVideoURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-\(UUID().uuidString).mov")
        try Data("not a real movie".utf8).write(to: url)
        return url
    }

    @Test func unreadableClipIsSkippedInsteadOfAbortingRebuild() async throws {
        // Regression: a single clip whose backing file can't be opened must not
        // throw out of build() and blank the whole preview — it should be skipped.
        let badURL = try garbageVideoURL()
        defer { try? FileManager.default.removeItem(at: badURL) }

        let clip = Fixtures.clip(mediaRef: "bad", start: 0, duration: 30)
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        // Should NOT throw — the bad clip is skipped and a composition returns.
        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { $0 == "bad" ? badURL : nil },
            renderSize: renderSize
        )
        #expect(result.composition.duration.isValid)
    }
}

// MARK: - affineTransform

@Suite("CompositionBuilder.affineTransform")
struct AffineTransformTests {

    private let render = CGSize(width: 1920, height: 1080)
    private let nat = CGSize(width: 1920, height: 1080)

    private func approxEqual(_ a: CGAffineTransform, _ b: CGAffineTransform, eps: CGFloat = 1e-9) -> Bool {
        abs(a.a - b.a) < eps && abs(a.b - b.b) < eps &&
        abs(a.c - b.c) < eps && abs(a.d - b.d) < eps &&
        abs(a.tx - b.tx) < eps && abs(a.ty - b.ty) < eps
    }

    @Test func defaultTransformWithMatchingSizesIsIdentity() {
        // Default Transform fills the canvas at native size — should produce the identity matrix.
        let result = CompositionBuilder.affineTransform(for: Transform(), natSize: nat, renderSize: render)
        #expect(approxEqual(result, .identity))
    }

    @Test func halfSizeAtCenterScalesAndTranslates() {
        // width=height=0.5 centered → sx=sy=0.5; topLeft=(0.25,0.25); tx=0.25*1920=480; ty=270.
        let t = Transform(centerX: 0.5, centerY: 0.5, width: 0.5, height: 0.5)
        let result = CompositionBuilder.affineTransform(for: t, natSize: nat, renderSize: render)
        let expected = CGAffineTransform(scaleX: 0.5, y: 0.5)
            .concatenating(CGAffineTransform(translationX: 480, y: 270))
        #expect(approxEqual(result, expected))
    }

    @Test func renderUpscalesBeyondNatSize() {
        // Source 1920×1080, render 3840×2160 → sx=sy=2 for a default fill transform.
        let bigRender = CGSize(width: 3840, height: 2160)
        let result = CompositionBuilder.affineTransform(for: Transform(), natSize: nat, renderSize: bigRender)
        #expect(abs(result.a - 2) < 1e-9)
        #expect(abs(result.d - 2) < 1e-9)
        #expect(result.tx == 0)
        #expect(result.ty == 0)
    }

    @Test func flipHorizontalNegatesXScaleAndShiftsTx() {
        // flipH=true → sx = -1; tx becomes (tl.x + width) * renderW = 1 * 1920 = 1920.
        // Net effect: mirror around the vertical center of the canvas.
        var t = Transform()
        t.flipHorizontal = true
        let result = CompositionBuilder.affineTransform(for: t, natSize: nat, renderSize: render)
        #expect(abs(result.a - (-1)) < 1e-9)
        #expect(abs(result.d - 1) < 1e-9)
        #expect(abs(result.tx - 1920) < 1e-9)
        #expect(result.ty == 0)
    }

    @Test func flipVerticalNegatesYScaleAndShiftsTy() {
        var t = Transform()
        t.flipVertical = true
        let result = CompositionBuilder.affineTransform(for: t, natSize: nat, renderSize: render)
        #expect(abs(result.a - 1) < 1e-9)
        #expect(abs(result.d - (-1)) < 1e-9)
        #expect(result.tx == 0)
        #expect(abs(result.ty - 1080) < 1e-9)
    }

    @Test func rotationAt180FlipsBothScales() {
        // A 180° rotation about the canvas center is equivalent to scaling both axes by -1
        // and translating by (renderW, renderH). Verifies that the rotation block composes
        // correctly with the prior placed transform.
        var t = Transform()
        t.rotation = 180
        let result = CompositionBuilder.affineTransform(for: t, natSize: nat, renderSize: render)
        let expected = CGAffineTransform(scaleX: -1, y: -1)
            .concatenating(CGAffineTransform(translationX: 1920, y: 1080))
        #expect(approxEqual(result, expected, eps: 1e-6))
    }

    @Test func zeroRotationSkipsRotationBlockEntirely() {
        // Same input minus the rotation should give the same matrix — the `guard rotation != 0`
        // path. Pinning down that the rotation block is genuinely a no-op at 0.
        var rotated = Transform()
        rotated.rotation = 0
        let plain = Transform()
        let a = CompositionBuilder.affineTransform(for: rotated, natSize: nat, renderSize: render)
        let b = CompositionBuilder.affineTransform(for: plain, natSize: nat, renderSize: render)
        #expect(approxEqual(a, b))
    }
}

// MARK: - Adversarial

@Suite("CompositionBuilder — adversarial")
struct CompositionBuilderAdversarialTests {

    @Test func affineTransformWithZeroNatSizeProducesInfiniteOrNaNScale() {
        // natSize=0 means scale = renderSize/0 = ∞ (or NaN if renderSize is also 0).
        // Caller must validate natSize > 0; we document the math here rather than crash.
        let result = CompositionBuilder.affineTransform(
            for: Transform(),
            natSize: CGSize(width: 0, height: 0),
            renderSize: CGSize(width: 1920, height: 1080)
        )
        #expect(result.a.isInfinite || result.a.isNaN)
    }
}
