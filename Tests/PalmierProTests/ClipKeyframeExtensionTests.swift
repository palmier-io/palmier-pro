import Testing
@testable import PalmierPro

/// Clip stores keyframes by clip-relative offset; the inspector and other callers work in
/// absolute timeline frames. These tests verify the translation through every public API.
@Suite("Clip keyframe extensions")
struct ClipKeyframeExtensionTests {

    // MARK: - keyframeFrames + allKeyframeFrames

    @Test func keyframeFramesAreAbsoluteNotClipRelative() {
        var clip = Fixtures.clip(start: 100, duration: 60)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 110, value: 0.5)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 150, value: 1.0)
        // Storage offsets are 10 and 50; public API returns absolute 110 and 150.
        #expect(clip.keyframeFrames(for: .opacity) == [10, 50].map { $0 + clip.startFrame })
    }

    @Test func keyframeFramesReturnsEmptyForUntouchedProperty() {
        let clip = Fixtures.clip(start: 0, duration: 30)
        #expect(clip.keyframeFrames(for: .opacity).isEmpty)
        #expect(clip.keyframeFrames(for: .position).isEmpty)
    }

    @Test func allKeyframeFramesIsSortedUnionAcrossProperties() {
        var clip = Fixtures.clip(start: 100, duration: 100)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 110, value: 1.0)
        clip.upsertKeyframe(in: \.scaleTrack, frame: 150, value: AnimPair(a: 1, b: 1))
        clip.upsertKeyframe(in: \.opacityTrack, frame: 180, value: 0.5)
        clip.upsertKeyframe(in: \.rotationTrack, frame: 110, value: 90) // same frame as opacity
        // Union dedupes; ascending sort.
        #expect(clip.allKeyframeFrames == [110, 150, 180])
    }

    // MARK: - upsertKeyframe

    @Test func upsertCreatesTrackIfAbsent() {
        var clip = Fixtures.clip(start: 0, duration: 30)
        #expect(clip.opacityTrack == nil)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 10, value: 0.5)
        #expect(clip.opacityTrack?.keyframes.count == 1)
    }

    @Test func upsertOnSameFrameReplacesValue() {
        var clip = Fixtures.clip(start: 100, duration: 60)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 130, value: 0.5)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 130, value: 0.9)
        #expect(clip.opacityTrack?.keyframes.count == 1)
        #expect(clip.opacityTrack?.keyframes[0].value == 0.9)
    }

    // MARK: - removeKeyframe

    @Test func removeKeyframeDropsByAbsoluteFrame() {
        var clip = Fixtures.clip(start: 100, duration: 60)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 110, value: 0.5)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 150, value: 1.0)
        clip.removeKeyframe(for: .opacity, at: 110)
        #expect(clip.keyframeFrames(for: .opacity) == [150])
    }

    @Test func removeLastKeyframeNilsTheTrack() {
        // The track is dropped to nil when empty so isActive checks elsewhere work correctly.
        var clip = Fixtures.clip(start: 100, duration: 60)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 110, value: 0.5)
        clip.removeKeyframe(for: .opacity, at: 110)
        #expect(clip.opacityTrack == nil)
    }

    @Test func removeKeyframeAtMissingFrameIsNoOp() {
        var clip = Fixtures.clip(start: 100, duration: 60)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 110, value: 0.5)
        clip.removeKeyframe(for: .opacity, at: 999) // not present
        #expect(clip.opacityTrack?.keyframes.count == 1)
    }

    // MARK: - clearKeyframes

    @Test func clearKeyframesDropsTheEntireTrack() {
        var clip = Fixtures.clip(start: 0, duration: 30)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 10, value: 0.5)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 20, value: 1.0)
        clip.clearKeyframes(for: .opacity)
        #expect(clip.opacityTrack == nil)
    }

    @Test func clearKeyframesOnlyAffectsTheNamedProperty() {
        var clip = Fixtures.clip(start: 0, duration: 30)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 10, value: 0.5)
        clip.upsertKeyframe(in: \.rotationTrack, frame: 10, value: 45)
        clip.clearKeyframes(for: .opacity)
        #expect(clip.opacityTrack == nil)
        #expect(clip.rotationTrack?.keyframes.count == 1)
    }

    // MARK: - setInterpolation

    @Test func setInterpolationChangesNamedKeyframeOnly() {
        var clip = Fixtures.clip(start: 100, duration: 60)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 110, value: 0.5)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 150, value: 1.0)
        clip.setInterpolation(for: .opacity, atFrame: 110, .hold)
        #expect(clip.interpolation(for: .opacity, atFrame: 110) == .hold)
        #expect(clip.interpolation(for: .opacity, atFrame: 150) != .hold)
    }

    @Test func setInterpolationAtMissingFrameIsNoOp() {
        var clip = Fixtures.clip(start: 100, duration: 60)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 110, value: 0.5)
        clip.setInterpolation(for: .opacity, atFrame: 999, .linear)
        // Original kf unchanged.
        #expect(clip.interpolation(for: .opacity, atFrame: 110) == .smooth)
    }

    // MARK: - moveKeyframe

    @Test func moveKeyframeRelocatesByAbsoluteFrame() {
        var clip = Fixtures.clip(start: 100, duration: 60)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 110, value: 0.5)
        clip.moveKeyframe(for: .opacity, from: 110, to: 140)
        #expect(clip.keyframeFrames(for: .opacity) == [140])
    }

    @Test func moveKeyframeOntoExistingFrameIsRefused() {
        // KeyframeTrack.move refuses on destination collision (per the earlier decision).
        // Clip wraps this behavior — both keyframes survive.
        var clip = Fixtures.clip(start: 100, duration: 60)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 110, value: 0.5)
        clip.upsertKeyframe(in: \.opacityTrack, frame: 140, value: 1.0)
        clip.moveKeyframe(for: .opacity, from: 110, to: 140)
        #expect(clip.opacityTrack?.keyframes.count == 2)
        #expect(clip.keyframeFrames(for: .opacity) == [110, 140])
    }
}
