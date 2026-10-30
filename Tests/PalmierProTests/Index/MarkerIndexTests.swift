import CoreGraphics
import Testing
@testable import PalmierPro

@Suite struct MarkerIndexTests {
    @Test func sortsMarkersByTimelinePositionAndStableId() {
        let markers = [
            TimelineMarker(id: "later", name: "Later", startFrame: 20),
            TimelineMarker(id: "b", name: "Second", startFrame: 10),
            TimelineMarker(id: "a", name: "First", startFrame: 10),
        ]
        let result = MarkerBrowserNavigation.sortedMarkers(markers, matching: "")
        #expect(result.map(\.id) == ["a", "b", "later"])
    }

    @Test func searchMatchesNamesAndCommentsCaseInsensitively() {
        let markers = [
            TimelineMarker(id: "name", name: "Opening Beat", startFrame: 0),
            TimelineMarker(id: "note", name: "Reaction", startFrame: 10, comment: "Hold on the OPENING shot"),
            TimelineMarker(id: "other", name: "Product", startFrame: 20),
        ]
        let result = MarkerBrowserNavigation.sortedMarkers(markers, matching: " opening ")
        #expect(result.map(\.id) == ["name", "note"])
    }

    @Test func filtersMarkersByReviewStatus() {
        let markers = [
            TimelineMarker(id: "open", name: "Open", startFrame: 0),
            TimelineMarker(id: "review", name: "Review", startFrame: 10, status: .review),
            TimelineMarker(id: "resolved", name: "Resolved", startFrame: 20, status: .resolved),
        ]
        let result = MarkerBrowserNavigation.sortedMarkers(markers, matching: "", status: .review)
        #expect(result.map(\.id) == ["review"])
    }

    @Test(arguments: [
        (canvas: CGSize(width: 1920, height: 1080), expectedWidth: CGFloat(96)),
        (canvas: CGSize(width: 1080, height: 1920), expectedWidth: CGFloat(30.375)),
    ])
    func thumbnailPreservesTimelineAspectRatio(canvas: CGSize, expectedWidth: CGFloat) {
        let size = MarkerThumbnailMetrics.size(canvas: canvas, height: 54)
        #expect(size.height == 54)
        #expect(abs(size.width - expectedWidth) < 0.000_001)
    }
}
