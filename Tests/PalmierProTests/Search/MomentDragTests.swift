import Foundation
import Testing
@testable import PalmierPro

@Suite("Moment drag payload")
@MainActor
struct MomentDragTests {
    @Test func segmentRoundTrips() {
        let s = MediaTab.assetDragString(forAssetId: "abc-123", segment: 12.5...20.25)
        #expect(MediaTab.assetId(fromDragString: s) == "abc-123")
        #expect(MediaTab.assetSegment(fromDragString: s) == 12.5...20.25)
    }

    @Test func plainAssetStringHasNoSegment() {
        let s = MediaTab.assetDragString(forAssetId: "abc-123")
        #expect(MediaTab.assetId(fromDragString: s) == "abc-123")
        #expect(MediaTab.assetSegment(fromDragString: s) == nil)
    }

    @Test func malformedSegmentsRejected() {
        #expect(MediaTab.assetSegment(fromDragString: "palmier-asset://x#5-2") == nil)
        #expect(MediaTab.assetSegment(fromDragString: "palmier-asset://x#-1-2") == nil)
        #expect(MediaTab.assetSegment(fromDragString: "palmier-asset://x#junk") == nil)
        #expect(MediaTab.assetSegment(fromDragString: "palmier-folder://x#1-2") == nil)
        #expect(MediaTab.assetId(fromDragString: "palmier-asset://x#junk") == "x")
    }

    @Test func zeroPrefixedFractionsParse() {
        let s = MediaTab.assetDragString(forAssetId: "x", segment: 0.0...0.5)
        #expect(MediaTab.assetSegment(fromDragString: s) == 0.0...0.5)
    }
}
