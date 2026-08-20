import CoreGraphics
import Testing
@testable import PalmierPro

@Suite("Mask point hit testing")
@MainActor
struct MaskPointHitTestingTests {
    private var timeline: Timeline {
        var timeline = Timeline()
        timeline.width = 100
        timeline.height = 100
        return timeline
    }

    @Test func mapsCanvasPointIntoSourceCoordinates() throws {
        let point = try #require(PreviewHitTester.sourceNormalizedPoint(
            at: CGPoint(x: 50, y: 150),
            viewSize: CGSize(width: 200, height: 200),
            clip: Clip(mediaRef: "media", startFrame: 0, durationFrames: 30),
            frame: 0,
            timeline: timeline
        ))
        #expect(abs(point.x - 0.25) < 0.000_001)
        #expect(abs(point.y - 0.75) < 0.000_001)
    }

    @Test func accountsForRotationAndFlip() throws {
        var clip = Clip(mediaRef: "media", startFrame: 0, durationFrames: 30)
        clip.transform.rotation = 90
        clip.transform.flipHorizontal = true
        let point = try #require(PreviewHitTester.sourceNormalizedPoint(
            at: CGPoint(x: 100, y: 50),
            viewSize: CGSize(width: 200, height: 200),
            clip: clip,
            frame: 0,
            timeline: timeline
        ))
        #expect(abs(point.x - 0.75) < 0.000_001)
        #expect(abs(point.y - 0.5) < 0.000_001)
    }

    @Test func rejectsCroppedAndTiltedRegions() {
        var cropped = Clip(mediaRef: "media", startFrame: 0, durationFrames: 30)
        cropped.crop.left = 0.2
        #expect(PreviewHitTester.sourceNormalizedPoint(
            at: CGPoint(x: 10, y: 100),
            viewSize: CGSize(width: 200, height: 200),
            clip: cropped,
            frame: 0,
            timeline: timeline
        ) == nil)

        var tilted = cropped
        tilted.crop = Crop()
        tilted.transform.rotationY = 10
        #expect(PreviewHitTester.sourceNormalizedPoint(
            at: CGPoint(x: 100, y: 100),
            viewSize: CGSize(width: 200, height: 200),
            clip: tilted,
            frame: 0,
            timeline: timeline
        ) == nil)
    }
}
