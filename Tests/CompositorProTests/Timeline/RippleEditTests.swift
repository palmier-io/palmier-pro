import Foundation
import Testing
@testable import CompositorPro

@Suite("Diff-based ripple")
struct RippleEditTests {
    private func snapshot(_ track: String, _ ranges: [Range<Int>]) throws -> RippleEdit.TrackSnapshot {
        try #require(RippleEdit.TrackSnapshot(trackId: track, intervals: ranges))
    }

    @Test func sameTrackRemovalClosesTheGap() throws {
        let before = [try snapshot("video", [0..<30, 30..<60, 60..<90])]
        let after = [try snapshot("video", [0..<30, 30..<60])]

        let adjustments = RippleEdit.adjustments(before: before, after: after)
        #expect(adjustments == [.init(trackId: "video", interval: 60..<90, delta: -30)])
    }

    @Test func crossTrackMoveEmitsBothSides() throws {
        let before = [try snapshot("video", [0..<30]), try snapshot("overlay", [])]
        let after = [try snapshot("video", []), try snapshot("overlay", [30..<60])]

        let adjustments = RippleEdit.adjustments(before: before, after: after)
        #expect(adjustments == [
            .init(trackId: "overlay", interval: 30..<60, delta: 30),
            .init(trackId: "video", interval: 0..<30, delta: -30),
        ])
    }

    @Test func identicalSnapshotsProduceNoAdjustments() throws {
        let before = [try snapshot("video", [0..<30, 45..<60])]
        let after = [try snapshot("video", [0..<30, 45..<60])]
        #expect(RippleEdit.adjustments(before: before, after: after).isEmpty)
    }

    @Test func gapsArePreservedRatherThanFilled() throws {
        // Pre-existing empty span 30..<45 is not "vacated" by the edit.
        let before = [try snapshot("video", [0..<30, 45..<60])]
        let after = [try snapshot("video", [0..<30])]
        let adjustments = RippleEdit.adjustments(before: before, after: after)
        #expect(adjustments == [.init(trackId: "video", interval: 45..<60, delta: -15)])
    }

    @Test func adjustmentsAreDeterministicAndOrderIndependent() throws {
        let video = try snapshot("video", [0..<30, 60..<90])
        let overlay = try snapshot("overlay", [0..<30])
        let editedVideo = try snapshot("video", [0..<30])
        let editedOverlay = try snapshot("overlay", [30..<60])

        let first = RippleEdit.adjustments(before: [video, overlay], after: [editedVideo, editedOverlay])
        let second = RippleEdit.adjustments(before: [overlay, video], after: [editedOverlay, editedVideo])
        #expect(first == second)
        #expect(first.map(\.trackId) == first.map(\.trackId).sorted())
    }

    @Test func applyingAdjustmentsShiftsLaterClipsAndRejectsOverlap() throws {
        let before = try snapshot("video", [0..<30, 60..<90])
        let adjustments = [RippleEdit.Adjustment(trackId: "video", interval: 60..<90, delta: -30)]
        let applied = try #require(RippleEdit.applying(adjustments, to: [before]))
        #expect(applied.first?.intervals == [0..<30, 30..<60])

        #expect(RippleEdit.TrackSnapshot(trackId: "video", intervals: [0..<10, 5..<20]) == nil)
    }

    @Test func invalidSnapshotIsRejectedByInit() {
        #expect(RippleEdit.TrackSnapshot(trackId: "video", intervals: [0..<30, 20..<40]) == nil)
        #expect(RippleEdit.TrackSnapshot(trackId: "video", intervals: [30..<40, 0..<20]) != nil)
    }
}
