import Testing
@testable import PalmierPro

@Suite("SnapEngine")
struct SnapEngineTests {

    // baseThreshold=8 pixels, pixelsPerFrame=4 → 2-frame base threshold.
    private let basePx: Double = 8
    private let pxPerFrame: Double = 4

    // MARK: - collectTargets

    @Test func collectTargetsEmptyTracksProducesNoTargets() {
        #expect(SnapEngine.collectTargets(tracks: [], includePlayhead: false).isEmpty)
    }

    @Test func collectTargetsIncludesPlayheadOnlyWhenRequested() {
        let withPlayhead = SnapEngine.collectTargets(tracks: [], playheadFrame: 75, includePlayhead: true)
        #expect(withPlayhead.count == 1)
        #expect(withPlayhead[0].frame == 75)
        #expect(withPlayhead[0].kind == .playhead)

        let without = SnapEngine.collectTargets(tracks: [], playheadFrame: 75, includePlayhead: false)
        #expect(without.isEmpty)
    }

    @Test func collectTargetsProducesStartAndEndForEachClip() {
        let track = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "a", start: 0, duration: 50),
            Fixtures.clip(id: "b", start: 100, duration: 80),
        ])
        let targets = SnapEngine.collectTargets(tracks: [track])
        let frames = targets.map(\.frame).sorted()
        #expect(frames == [0, 50, 100, 180])
        #expect(targets.allSatisfy { $0.kind == .clipEdge })
    }

    @Test func collectTargetsSkipsExcludedClipIds() {
        let track = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "drag", start: 0, duration: 50),
            Fixtures.clip(id: "static", start: 100, duration: 80),
        ])
        let targets = SnapEngine.collectTargets(tracks: [track], excludeClipIds: ["drag"])
        let frames = targets.map(\.frame).sorted()
        #expect(frames == [100, 180])
    }

    // MARK: - findSnap (basic threshold)

    @Test func findSnapReturnsNilWhenNoTargets() {
        var state = SnapEngine.SnapState()
        let result = SnapEngine.findSnap(
            position: 100,
            targets: [],
            state: &state,
            baseThreshold: basePx,
            pixelsPerFrame: pxPerFrame
        )
        #expect(result == nil)
        #expect(state.currentlySnappedTo == nil)
    }

    @Test func findSnapReturnsNilWhenBeyondThreshold() {
        let targets = [SnapEngine.SnapTarget(frame: 50, kind: .clipEdge)]
        var state = SnapEngine.SnapState()
        // pos=55, dist=5, frame threshold=2 → no snap
        let result = SnapEngine.findSnap(
            position: 55,
            targets: targets,
            state: &state,
            baseThreshold: basePx,
            pixelsPerFrame: pxPerFrame
        )
        #expect(result == nil)
        #expect(state.currentlySnappedTo == nil)
    }

    @Test func findSnapSnapsWithinThreshold() {
        let targets = [SnapEngine.SnapTarget(frame: 50, kind: .clipEdge)]
        var state = SnapEngine.SnapState()
        // pos=49, dist=1, within frame threshold of 2 → snaps to 50
        let result = SnapEngine.findSnap(
            position: 49,
            targets: targets,
            state: &state,
            baseThreshold: basePx,
            pixelsPerFrame: pxPerFrame
        )
        #expect(result?.frame == 50)
        #expect(result?.probeOffset == 0)
        #expect(result?.x == 200) // 50 * 4
        #expect(state.currentlySnappedTo == 50)
    }

    @Test func findSnapPicksClosestOfMultipleTargets() {
        let targets = [
            SnapEngine.SnapTarget(frame: 49, kind: .clipEdge),
            SnapEngine.SnapTarget(frame: 51, kind: .clipEdge),
        ]
        var state = SnapEngine.SnapState()
        // pos=50, dist to 49 = 1, dist to 51 = 1 — first wins on equal distance (strict <).
        let result = SnapEngine.findSnap(
            position: 50,
            targets: targets,
            state: &state,
            baseThreshold: basePx,
            pixelsPerFrame: pxPerFrame
        )
        #expect(result?.frame == 49)
    }

    // MARK: - findSnap (sticky behavior)

    @Test func findSnapStaysStickyWithinHoldThreshold() {
        let targets = [SnapEngine.SnapTarget(frame: 50, kind: .clipEdge)]
        var state = SnapEngine.SnapState()

        _ = SnapEngine.findSnap(
            position: 49,
            targets: targets,
            state: &state,
            baseThreshold: basePx,
            pixelsPerFrame: pxPerFrame
        )
        #expect(state.currentlySnappedTo == 50)

        // Hold threshold = 2 * 1.5 = 3 frames; pos=53 is exactly at the boundary, still stuck.
        let stuck = SnapEngine.findSnap(
            position: 53,
            targets: targets,
            state: &state,
            baseThreshold: basePx,
            pixelsPerFrame: pxPerFrame
        )
        #expect(stuck?.frame == 50)
        #expect(state.currentlySnappedTo == 50)
    }

    @Test func findSnapReleasesStickyBeyondHoldThreshold() {
        let targets = [SnapEngine.SnapTarget(frame: 50, kind: .clipEdge)]
        var state = SnapEngine.SnapState()

        _ = SnapEngine.findSnap(
            position: 49,
            targets: targets,
            state: &state,
            baseThreshold: basePx,
            pixelsPerFrame: pxPerFrame
        )

        // pos=54, dist=4 > hold threshold (3) → unsnaps; new search dist=4 > base threshold (2) → nil.
        let result = SnapEngine.findSnap(
            position: 54,
            targets: targets,
            state: &state,
            baseThreshold: basePx,
            pixelsPerFrame: pxPerFrame
        )
        #expect(result == nil)
        #expect(state.currentlySnappedTo == nil)
    }

    @Test func findSnapReleasesWhenStickyTargetDisappears() {
        var state = SnapEngine.SnapState()

        let initial = [SnapEngine.SnapTarget(frame: 50, kind: .clipEdge)]
        _ = SnapEngine.findSnap(
            position: 49,
            targets: initial,
            state: &state,
            baseThreshold: basePx,
            pixelsPerFrame: pxPerFrame
        )
        #expect(state.currentlySnappedTo == 50)

        // Sticky target frame 50 is no longer in the target list — sticky branch must release.
        let updated = [SnapEngine.SnapTarget(frame: 200, kind: .clipEdge)]
        let result = SnapEngine.findSnap(
            position: 50,
            targets: updated,
            state: &state,
            baseThreshold: basePx,
            pixelsPerFrame: pxPerFrame
        )
        #expect(result == nil)
        #expect(state.currentlySnappedTo == nil)
    }

    // MARK: - findSnap (playhead multiplier)

    @Test func playheadHasWiderThreshold() {
        let targets = [SnapEngine.SnapTarget(frame: 100, kind: .playhead)]
        var state = SnapEngine.SnapState()
        // pos=103, dist=3. Clip-edge would need ≤2, but playhead threshold is 2 * 1.5 = 3 → snaps.
        let result = SnapEngine.findSnap(
            position: 103,
            targets: targets,
            state: &state,
            baseThreshold: basePx,
            pixelsPerFrame: pxPerFrame
        )
        #expect(result?.frame == 100)
    }

    @Test func playheadStillFailsOutsideItsWiderThreshold() {
        let targets = [SnapEngine.SnapTarget(frame: 100, kind: .playhead)]
        var state = SnapEngine.SnapState()
        // pos=104, dist=4 > 3 → no snap.
        let result = SnapEngine.findSnap(
            position: 104,
            targets: targets,
            state: &state,
            baseThreshold: basePx,
            pixelsPerFrame: pxPerFrame
        )
        #expect(result == nil)
    }

    // MARK: - findSnap (multiple probe offsets)

    @Test func multipleProbesPicksClosestProbeTargetPair() {
        // pos=70 with probeOffsets [0, 30]: probe0=70 (dist to 50 = 20), probe30=100 (dist to 100 = 0).
        // Probe 30 + target 100 wins.
        let targets = [
            SnapEngine.SnapTarget(frame: 50, kind: .clipEdge),
            SnapEngine.SnapTarget(frame: 100, kind: .clipEdge),
        ]
        var state = SnapEngine.SnapState()
        let result = SnapEngine.findSnap(
            position: 70,
            probeOffsets: [0, 30],
            targets: targets,
            state: &state,
            baseThreshold: basePx,
            pixelsPerFrame: pxPerFrame
        )
        #expect(result?.frame == 100)
        #expect(result?.probeOffset == 30)
        #expect(state.currentProbeOffset == 30)
    }
}
