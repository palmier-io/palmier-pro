import AppKit
import Testing
@testable import PalmierPro

@Suite("TimelineGeometry")
struct TimelineGeometryTests {

    // Three tracks of 50 each. baseY = rulerHeight (24) + dropZoneHeight (60) = 84.
    // cumulativeY = [84, 134, 184]; track bottoms = [134, 184, 234]. All assertions below derive from this.
    private func geometry(pxPerFrame: Double = 4, header: Double = 0) -> TimelineGeometry {
        TimelineGeometry(
            pixelsPerFrame: pxPerFrame,
            headerWidth: header,
            trackHeights: [50, 50, 50]
        )
    }

    // MARK: - Frame ↔ X

    @Test func frameAtAndXForFrameRoundtrip() {
        let g = geometry()
        #expect(g.xForFrame(100) == 400) // 100 * 4
        #expect(g.frameAt(x: 400) == 100)
    }

    @Test func xForFrameIncludesHeaderWidth() {
        let g = geometry(header: 100)
        #expect(g.xForFrame(50) == 300) // 100 + 50*4
        #expect(g.frameAt(x: 300) == 50)
    }

    @Test func frameAtBeforeHeaderClampsToZero() {
        let g = geometry(header: 100)
        #expect(g.frameAt(x: 0) == 0)
    }

    // MARK: - Track Y

    @Test func trackYReturnsCumulativeOffsets() {
        let g = geometry()
        #expect(g.trackY(at: 0) == 84)
        #expect(g.trackY(at: 1) == 134)
        #expect(g.trackY(at: 2) == 184)
    }

    @Test func trackYOutOfBoundsReturnsRulerHeight() {
        let g = geometry()
        #expect(g.trackY(at: 99) == Layout.rulerHeight)
    }

    // MARK: - Clip rect

    @Test func clipRectInsetsTwoPxTopAndBottom() {
        let g = geometry()
        let clip = Fixtures.clip(start: 100, duration: 50)
        let rect = g.clipRect(for: clip, trackIndex: 0)
        // x = 100*4 = 400. y = 84 + 2 = 86. w = 50*4 = 200. h = 50 - 4 = 46.
        #expect(rect.origin.x == 400)
        #expect(rect.origin.y == 86)
        #expect(rect.size.width == 200)
        #expect(rect.size.height == 46)
    }

    // MARK: - trackAt

    @Test func trackAtReturnsCorrectTrackIndex() {
        let g = geometry()
        #expect(g.trackAt(y: 100) == 0)  // 84 ≤ 100 < 134
        #expect(g.trackAt(y: 140) == 1)  // 134 ≤ 140 < 184
        #expect(g.trackAt(y: 200) == 2)  // 184 ≤ 200 < 234
    }

    @Test func trackAtBelowLastTrackClampsToLast() {
        let g = geometry()
        #expect(g.trackAt(y: 1000) == 2)
    }

    // MARK: - dropTargetAt

    @Test func dropTargetAboveFirstTrackIsNewTrackAtZero() {
        let g = geometry()
        // y < cumY[0] (84)
        #expect(g.dropTargetAt(y: 50) == .newTrackAt(0))
    }

    @Test func dropTargetBetweenTracksWithinThresholdIsNewTrack() {
        let g = geometry()
        // Boundary between track 0 and 1 is at y=134. Threshold is 10. Range [124, 144].
        #expect(g.dropTargetAt(y: 130) == .newTrackAt(1))
        #expect(g.dropTargetAt(y: 134) == .newTrackAt(1))
    }

    @Test func dropTargetOnExistingTrackBodyIsExistingTrack() {
        let g = geometry()
        // Track 0 body is [84, 134). Outside the boundary zones — y=100 should land in body.
        #expect(g.dropTargetAt(y: 100) == .existingTrack(0))
        #expect(g.dropTargetAt(y: 200) == .existingTrack(2))
    }

    @Test func dropTargetBelowLastTrackIsNewTrackAtCount() {
        let g = geometry()
        // Last track bottom is 234.
        #expect(g.dropTargetAt(y: 250) == .newTrackAt(3))
    }

    @Test func dropTargetWithEmptyTimelineIsNewTrackAtZero() {
        let g = TimelineGeometry(pixelsPerFrame: 4, trackHeights: [])
        #expect(g.dropTargetAt(y: 100) == .newTrackAt(0))
    }

    // MARK: - insertionLineY

    @Test func insertionLineYIsNilForExistingTrack() {
        let g = geometry()
        #expect(g.insertionLineY(for: .existingTrack(1)) == nil)
    }

    @Test func insertionLineYAtTopReturnsFirstCumulative() {
        let g = geometry()
        #expect(g.insertionLineY(for: .newTrackAt(0)) == 84)
    }

    @Test func insertionLineYBetweenTracksReturnsBoundary() {
        let g = geometry()
        #expect(g.insertionLineY(for: .newTrackAt(1)) == 134)
        #expect(g.insertionLineY(for: .newTrackAt(2)) == 184)
    }

    @Test func insertionLineYAtBottomReturnsLastBottom() {
        let g = geometry()
        // index == trackCount → last cumulativeY + last height = 184 + 50 = 234.
        #expect(g.insertionLineY(for: .newTrackAt(3)) == 234)
    }
}
