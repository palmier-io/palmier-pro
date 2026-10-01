import Foundation
import Testing
@testable import CompositorPro

/// A ramp survives a project round trip, so opening a project restores the same curve.
@Suite("speedTrack persistence")
struct SpeedTrackPersistenceTests {
    @Test func clipRoundTripsThroughJSONWithItsRamp() throws {
        var clip = Fixtures.clip(id: "ramp", mediaRef: "m", start: 0, duration: 300)
        clip.speed = 1
        clip.speedTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 1, interpolationOut: .linear),
            Keyframe(frame: 150, value: 3, interpolationOut: .linear),
        ])

        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(Clip.self, from: data)

        #expect(decoded.speedTrack?.keyframes.count == 2)
        #expect(decoded.speedTrack?.keyframes.map(\.frame) == [0, 150])
        #expect(decoded.speedTrack?.keyframes.map(\.value) == [1, 3])
        #expect(decoded.timeMap == clip.timeMap)
    }

    @Test func aClipWithoutARampDecodesWithNoTrack() throws {
        let clip = Fixtures.clip(id: "flat", mediaRef: "m", start: 0, duration: 300)
        let decoded = try JSONDecoder().decode(Clip.self, from: try JSONEncoder().encode(clip))
        #expect(decoded.speedTrack == nil)
        #expect(decoded.timeMap.isConstantSpeed)
    }

    @Test func rescalingTheClipRescalesTheRamp() {
        var clip = Fixtures.clip(id: "ramp", mediaRef: "m", start: 0, duration: 100)
        clip.speedTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 1),
            Keyframe(frame: 50, value: 3),
            Keyframe(frame: 100, value: 2),
        ])
        // The domain sets the new length first, then rescales against it.
        clip.durationFrames = 200
        clip.rescaleKeyframes(by: 2)
        #expect(clip.speedTrack?.keyframes.map(\.frame) == [0, 100, 199])
    }

    @Test func clampingDropsRampRowsPastTheClipEnd() {
        var clip = Fixtures.clip(id: "ramp", mediaRef: "m", start: 0, duration: 100)
        clip.speedTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 1),
            Keyframe(frame: 40, value: 2),
            Keyframe(frame: 500, value: 8),
        ])
        clip.clampKeyframesToDuration()
        // Same rule every keyframe track uses: a row outside the clip is dropped, not folded
        // onto the last frame, so a stale row cannot silently change the curve's tail.
        #expect(clip.speedTrack?.keyframes.map(\.frame) == [0, 40])
    }

    @Test func averageSpeedIsExposedForConsumersThatNeedOneNumber() {
        var clip = Fixtures.clip(id: "ramp", mediaRef: "m", start: 0, duration: 100)
        clip.speedTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 2),
            Keyframe(frame: 99, value: 4),
        ])
        #expect(abs(clip.timeMap.averageSpeed - 3) < 0.05)
    }
}
