import Foundation
import Testing
@testable import CompositorPro

@Suite("Marker color labels")
struct MarkerColorLabelTests {
    @Test func legacyMarkersDecodeWithoutALabel() throws {
        let legacy = """
        {"id":"m1","name":"Intro","startFrame":0,"durationFrames":0,"color":{"r":0,"g":0.478,"b":1,"a":1},"comment":"note"}
        """
        let marker = try JSONDecoder().decode(TimelineMarker.self, from: Data(legacy.utf8))
        #expect(marker.colorLabel == nil)
        #expect(marker.comment == "note")
        #expect(marker.isRange == false)
    }

    @Test func labelRoundTripsAndDrivesTheColor() throws {
        var marker = TimelineMarker(name: "Look", startFrame: 10, durationFrames: 30, comment: "grade pass")
        marker.colorLabel = .orange
        marker.adoptColorLabel()
        let data = try JSONEncoder().encode(marker)
        let decoded = try JSONDecoder().decode(TimelineMarker.self, from: data)
        #expect(decoded.colorLabel == .orange)
        #expect(decoded.color == MarkerColorLabel.orange.color)
        #expect(decoded.isRange)
        #expect(decoded.comment == "grade pass")
    }

    @Test func everyLabelHasItsOwnColor() {
        let colors = MarkerColorLabel.allCases.map(\.color)
        #expect(Set(colors.map { "\($0.r),\($0.g),\($0.b)" }).count == colors.count)
    }

    @Test func pointAndRangeBookmarksKeepTheirMeaning() {
        let point = TimelineMarker(name: "Beat", startFrame: 42)
        #expect(!point.isRange)
        #expect(point.endFrame == 42)
        var range = TimelineMarker(name: "Scene", startFrame: 10, durationFrames: 40)
        #expect(range.isRange)
        #expect(range.endFrame == 50)
        range.rescaleFrames(by: 2)
        #expect(range.startFrame == 20)
    }
}
