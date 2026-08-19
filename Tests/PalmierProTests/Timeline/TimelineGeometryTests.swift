import AppKit
import Testing
@testable import PalmierPro

@Suite("TimelineGeometry")
struct TimelineGeometryTests {

    // Three tracks of 50 each start at rulerHeight (28) + dropZoneHeight (32) = 60.
    private func geometry(
        pxPerFrame: Double = 4,
        header: Double = 0,
        lanes: [[AnimatableProperty]] = []
    ) -> TimelineGeometry {
        TimelineGeometry(
            pixelsPerFrame: pxPerFrame,
            headerWidth: header,
            trackHeights: [50, 50, 50],
            laneProperties: lanes
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
        #expect(g.trackY(at: 0) == 60)
        #expect(g.trackY(at: 1) == 110)
        #expect(g.trackY(at: 2) == 160)
    }

    @Test func trackYOutOfBoundsReturnsRulerHeight() {
        let g = geometry()
        #expect(g.trackY(at: 99) == Layout.rulerHeight)
    }

    @Test func expandedLanesShiftFollowingTracksAndContentBottom() {
        let laneHeight = AppTheme.ComponentSize.timelineKeyframeLaneHeight
        let g = geometry(lanes: [[.position, .opacity], [], [.volume]])

        #expect(g.trackY(at: 0) == 60)
        #expect(g.trackY(at: 1) == 110 + laneHeight * 2)
        #expect(g.trackY(at: 2) == 160 + laneHeight * 2)
        #expect(g.contentBottom == 210 + laneHeight * 3)
    }

    @Test func rowLocationDistinguishesTrackAndPropertyLanes() {
        let g = geometry(lanes: [[.position, .opacity], [], []])
        let firstLaneY = g.trackY(at: 0) + g.trackHeight(at: 0)

        #expect(g.rowLocation(atY: Double(g.trackY(at: 0) + 10)) == .track(0))
        #expect(g.rowLocation(atY: Double(firstLaneY + 2)) == .keyframeLane(
            trackIndex: 0,
            property: .position
        ))
        #expect(g.rowLocation(
            atY: Double(firstLaneY + AppTheme.ComponentSize.timelineKeyframeLaneHeight + 2)
        ) == .keyframeLane(trackIndex: 0, property: .opacity))
    }

    // MARK: - Clip rect

    @Test func clipRectInsetsTwoPxTopAndBottom() {
        let g = geometry()
        let clip = Fixtures.clip(start: 100, duration: 50)
        let rect = g.clipRect(for: clip, trackIndex: 0)
        // x = 100*4 = 400. y = 60 + 2 = 62. w = 50*4 = 200. h = 50 - 4 = 46.
        #expect(rect.origin.x == 400)
        #expect(rect.origin.y == 62)
        #expect(rect.size.width == 200)
        #expect(rect.size.height == 46)
    }

    // MARK: - trackAt

    @Test func trackAtReturnsCorrectTrackIndex() {
        let g = geometry()
        #expect(g.trackAt(y: 100) == 0)
        #expect(g.trackAt(y: 140) == 1)
        #expect(g.trackAt(y: 200) == 2)
    }

    @Test func trackAtBelowLastTrackClampsToLast() {
        let g = geometry()
        #expect(g.trackAt(y: 1000) == 2)
    }

    // MARK: - dropTargetAt

    @Test func dropTargetAboveFirstTrackIsNewTrackAtZero() {
        let g = geometry()
        // y < cumY[0] (60)
        #expect(g.dropTargetAt(y: 50) == .newTrackAt(0))
    }

    @Test func dropTargetBetweenTracksWithinThresholdIsNewTrack() {
        let g = geometry()
        // Boundary between track 0 and 1 is at y=110. Threshold is 10.
        #expect(g.dropTargetAt(y: 106) == .newTrackAt(1))
        #expect(g.dropTargetAt(y: 110) == .newTrackAt(1))
    }

    @Test func dropTargetOnExistingTrackBodyIsExistingTrack() {
        let g = geometry()
        // Track 0 body is [60, 110). Outside the boundary zones.
        #expect(g.dropTargetAt(y: 90) == .existingTrack(0))
        #expect(g.dropTargetAt(y: 200) == .existingTrack(2))
    }

    @Test func dropTargetOnExpandedLaneTargetsOwningTrack() {
        let g = geometry(lanes: [[.position, .opacity], [], []])
        let y = g.trackY(at: 0) + g.trackHeight(at: 0) + 2
        #expect(g.dropTargetAt(y: Double(y)) == .existingTrack(0))
    }

    @Test func dropTargetBelowLastTrackIsNewTrackAtCount() {
        let g = geometry()
        // Last track bottom is 210.
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
        #expect(g.insertionLineY(for: .newTrackAt(0)) == 60)
    }

    @Test func insertionLineYBetweenTracksReturnsBoundary() {
        let g = geometry()
        #expect(g.insertionLineY(for: .newTrackAt(1)) == 110)
        #expect(g.insertionLineY(for: .newTrackAt(2)) == 160)
    }

    @Test func insertionLineYAtBottomReturnsLastBottom() {
        let g = geometry()
        #expect(g.insertionLineY(for: .newTrackAt(3)) == 210)
    }
}
