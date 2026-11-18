import Foundation
import Testing
@testable import CompositorPro

@Suite("Keyframe lanes and curves")
struct KeyframeLaneTests {
    private func clipWithKeyframes() -> Clip {
        var clip = Fixtures.clip(id: "animated", start: 0, duration: 60)
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0), Keyframe(frame: 30, value: 1),
        ])
        clip.scaleTrack = KeyframeTrack(keyframes: [Keyframe(frame: 0, value: AnimPair(a: 1, b: 1))])
        return clip
    }

    @Test func lanesShowOnlyAnimatedPropertiesInInspectorOrder() {
        let lanes = KeyframeLanes.lanes(for: clipWithKeyframes())
        #expect(lanes.map(\.property) == ["scale", "opacity"])
        #expect(lanes.first(where: { $0.property == "opacity" })?.frames == [0, 30])
    }

    @Test func clipWithoutKeyframesHasNoLanes() {
        #expect(KeyframeLanes.lanes(for: Fixtures.clip(start: 0, duration: 30)).isEmpty)
    }

    @Test func curveHitsEndpointsAndStaysMonotonic() {
        for curve in [KeyframeCurve.linear, .easeIn, .easeOut, .easeInOut] {
            #expect(curve.progress(at: 0) == 0)
            #expect(curve.progress(at: 1) == 1)
            var previous = -1.0
            for step in 0...20 {
                let value = curve.progress(at: Double(step) / 20)
                #expect(value >= previous - 1e-9)
                previous = value
            }
        }
    }

    @Test func curveControlPointsClampIntoRange() {
        let curve = KeyframeCurve(control1X: -3, control1Y: 9, control2X: 4, control2Y: -9)
        #expect(curve.control1X == 0 && curve.control2X == 1)
        #expect(curve.control1Y == 2 && curve.control2Y == -1)
        #expect(KeyframeCurve(control1X: .nan, control1Y: .nan, control2X: .nan, control2Y: .nan).control1X == 0)
    }

    @Test func copyPasteAppliesOnlyMatchingProperties() {
        let source = clipWithKeyframes()
        let payload = KeyframeClipboard.copy(from: source)
        #expect(!payload.isEmpty)

        var target = Fixtures.clip(id: "target", start: 0, duration: 60)
        target.opacityTrack = KeyframeTrack(keyframes: [Keyframe(frame: 0, value: 0.5)])
        #expect(KeyframeClipboard.paste(payload, into: &target))
        #expect(target.opacityTrack?.keyframes.map(\.value) == [0, 1])
        // Scale was not animated on the target, so it is not created by a paste.
        #expect(target.scaleTrack == nil)

        var empty = Fixtures.clip(id: "empty", start: 0, duration: 60)
        #expect(!KeyframeClipboard.paste(payload, into: &empty))
    }
}
