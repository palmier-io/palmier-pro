import AppKit
import Testing
@testable import PalmierPro

@Suite("Timeline keyframe lanes")
struct TimelineKeyframeLaneTests {
    @MainActor
    @Test func expansionStateKeepsMultipleTracksOpenAndPrunesDeletedTracks() {
        let state = TimelineKeyframeLaneState()
        state.toggle(trackId: "video")
        state.toggle(trackId: "audio")

        #expect(state.expandedTrackIds == ["video", "audio"])

        state.prune(validTrackIds: ["audio"])

        #expect(state.expandedTrackIds == ["audio"])
    }

    @Test func textSupportsScaleButNotCropOrVolume() {
        let text = Fixtures.clip(mediaType: .text, start: 0, duration: 30)

        #expect(text.supportsKeyframes(for: .position))
        #expect(text.supportsKeyframes(for: .rotation))
        #expect(text.supportsKeyframes(for: .opacity))
        #expect(text.supportsKeyframes(for: .blur))
        #expect(text.supportsKeyframes(for: .scale))
        #expect(!text.supportsKeyframes(for: .crop))
        #expect(!text.supportsKeyframes(for: .volume))
    }

    @Test func mixedVisualTrackUsesUnionOfSupportedLanes() {
        let track = Fixtures.videoTrack(clips: [
            Fixtures.clip(mediaType: .text, start: 0, duration: 30),
            Fixtures.clip(mediaType: .video, start: 30, duration: 30),
        ])

        #expect(AnimatableProperty.lanes(for: track) == [
            .position, .scale, .rotation, .opacity, .blur, .crop,
        ])
    }

    @Test func textOnlyAndAudioTracksExposeTheirOwnLaneSets() {
        let textTrack = Fixtures.videoTrack(clips: [
            Fixtures.clip(mediaType: .text, start: 0, duration: 30),
        ])
        let audioTrack = Fixtures.audioTrack(clips: [
            Fixtures.clip(mediaType: .audio, start: 0, duration: 30),
        ])

        #expect(AnimatableProperty.lanes(for: textTrack) == [
            .position, .scale, .rotation, .opacity, .blur,
        ])
        #expect(AnimatableProperty.lanes(for: audioTrack).isEmpty)
    }

    @Test func cropInsetsPreserveMinimumVisibleArea() {
        var crop = Crop(right: 0.4, bottom: 0.25)

        crop.setInset(1, edge: .left)
        crop.setInset(1, edge: .top)

        #expect(abs(crop.visibleWidthFraction - Crop.minimumVisibleFraction) < 1e-12)
        #expect(abs(crop.visibleHeightFraction - Crop.minimumVisibleFraction) < 1e-12)
    }

    @Test func cropInsetsIgnoreNonFiniteValues() {
        var crop = Crop(left: 0.1)

        crop.setInset(.nan, edge: .left)

        #expect(crop.left == 0.1)
    }

    @Test func durationClampMovesBoundaryKeyframeToLastFrame() {
        var clip = Fixtures.clip(start: 0, duration: 10)
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 9, value: 0.5),
            Keyframe(frame: 10, value: 1),
        ])

        clip.clampKeyframesToDuration()

        #expect(clip.opacityTrack?.keyframes.map(\.frame) == [9])
        #expect(clip.opacityTrack?.keyframes.first?.value == 1)
    }

    @Test func keyframeRescalingClampsRoundingToLastFrame() {
        var clip = Fixtures.clip(start: 0, duration: 10)
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 9, value: 0.5),
        ])
        clip.durationFrames = 4

        clip.rescaleKeyframes(by: 0.4)

        #expect(clip.opacityTrack?.keyframes.map(\.frame) == [3])
    }

    @MainActor
    @Test func togglingExistingVolumeKeyframeRemovesIt() {
        var audio = Fixtures.clip(id: "audio", mediaType: .audio, start: 10, duration: 30)
        audio.volumeTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 5, value: -8, interpolationOut: .linear),
        ])
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.audioTrack(clips: [audio]),
        ])
        let undo = UndoManager()
        editor.undo.attach(undo)
        undo.removeAllActions()

        editor.toggleKeyframe(
            clipId: audio.id,
            property: .volume,
            at: 15
        )

        #expect(editor.clipFor(id: audio.id)?.volumeTrack == nil)
        #expect(undo.canUndo)
        undo.undo()
        #expect(editor.clipFor(id: audio.id)?.volumeTrack == audio.volumeTrack)
    }

    @MainActor
    @Test func targetUsesEligibleClipUnderPlayheadAndReturnsNilForGaps() {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(id: "visual", clips: [
                Fixtures.clip(id: "text", mediaType: .text, start: 0, duration: 20),
                Fixtures.clip(id: "video", mediaType: .video, start: 30, duration: 20),
            ]),
        ])

        #expect(editor.keyframeLaneTarget(trackId: "visual", property: .opacity, at: 10)?.id == "text")
        #expect(editor.keyframeLaneTarget(trackId: "visual", property: .scale, at: 10)?.id == "text")
        #expect(editor.keyframeLaneTarget(trackId: "visual", property: .opacity, at: 25) == nil)
        #expect(editor.keyframeLaneTarget(trackId: "visual", property: .crop, at: 10) == nil)
        #expect(editor.keyframeLaneTarget(trackId: "visual", property: .crop, at: 35)?.id == "video")
    }

    @MainActor
    @Test func navigationCrossesClipBoundariesOnThePropertyLane() {
        var first = Fixtures.clip(id: "first", start: 0, duration: 20)
        first.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 5, value: 0.5),
        ])
        var second = Fixtures.clip(id: "second", start: 30, duration: 20)
        second.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 10, value: 0.8),
        ])
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(id: "visual", clips: [first, second]),
        ])

        var navigation = editor.keyframeLaneNavigationTargets(
            trackId: "visual",
            property: .opacity,
            around: 25
        )
        #expect(navigation.previous == KeyframeLaneNavigationTarget(clipId: "first", frame: 5))
        #expect(navigation.next == KeyframeLaneNavigationTarget(clipId: "second", frame: 40))

        editor.commitClipProperty(clipId: "second") {
            $0.upsertKeyframe(in: \.opacityTrack, frame: 35, value: 0.7)
        }
        navigation = editor.keyframeLaneNavigationTargets(
            trackId: "visual",
            property: .opacity,
            around: 25
        )
        #expect(navigation.next == KeyframeLaneNavigationTarget(clipId: "second", frame: 35))
    }

    @MainActor
    @Test func opacityWriteUpdatesTextKeyframeAtPlayhead() {
        var text = Fixtures.clip(id: "text", mediaType: .text, start: 10, duration: 30)
        text.opacity = 0.8
        text.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0.2),
        ])
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [text]),
        ])
        editor.currentFrame = 20

        editor.applyOpacity(clipId: text.id, value: 0.6)

        let result = editor.clipFor(id: text.id)
        #expect(result?.opacity == 0.8)
        #expect(result?.opacityTrack?.keyframes.first(where: { $0.frame == 10 })?.value == 0.6)
    }

    @MainActor
    @Test func sizeWriteAndRefitPreserveTextScaleAnimation() throws {
        var text = Fixtures.clip(id: "text", mediaType: .text, start: 0, duration: 30)
        text.transform = Transform(width: 0.2, height: 0.1)
        text.textStyle = TextStyle()
        text.scaleTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: AnimPair(a: 0.2, b: 0.1)),
        ])
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [text]),
        ])
        editor.currentFrame = 10

        editor.applyTextSize(clipId: text.id, value: 144)

        var result = try #require(editor.clipFor(id: text.id))
        let keyframe = try #require(result.scaleTrack?.keyframes.first { $0.frame == 10 })
        #expect(abs(keyframe.value.a - 0.3) < 0.000_001)
        #expect(abs(keyframe.value.b - 0.15) < 0.000_001)
        result.textContent = "Scale across a wider line"
        #expect(editor.fitTextClipToContentIfNeeded(&result, canvasW: 1_920, canvasH: 1_080))
        #expect(abs(result.textStyleAt(frame: 10).scaledVisualStyle.fontSize - 144) < 0.000_001)
    }

    @MainActor
    @Test func animatedFieldEditUndoesAsOneAction() {
        var clip = Fixtures.clip(id: "clip", start: 0, duration: 30)
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0.2),
        ])
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [clip]),
        ])
        editor.currentFrame = 10
        let undo = UndoManager()
        editor.undo.attach(undo)
        undo.removeAllActions()

        editor.applyOpacity(clipId: clip.id, value: 0.6)
        editor.commitOpacity(clipId: clip.id, value: 0.6)

        #expect(undo.canUndo)
        undo.undo()
        #expect(editor.clipFor(id: clip.id)?.opacityTrack?.keyframes == [
            Keyframe(frame: 0, value: 0.2),
        ])
        #expect(!undo.canUndo)
    }

    @MainActor
    @Test func animatedFieldEditOutsideClipDoesNotCreateOutOfRangeKeyframe() {
        var clip = Fixtures.clip(id: "clip", start: 10, duration: 20)
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0.2),
        ])
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [clip]),
        ])
        editor.currentFrame = 0

        editor.applyOpacity(clipId: clip.id, value: 0.6)

        #expect(editor.clipFor(id: clip.id) == clip)
    }

    @MainActor
    @Test func laneHitResolvesClipAndAbsoluteFrame() throws {
        var clip = Fixtures.clip(id: "clip", start: 10, duration: 30)
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 5, value: 0.5),
        ])
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [clip]),
        ])
        let view = TimelineView(editor: editor)
        let geometry = TimelineGeometry(
            pixelsPerFrame: 2,
            trackHeights: editor.timeline.tracks.map(\.displayHeight),
            laneProperties: [[.opacity]],
            bounds: NSRect(x: 0, y: 0, width: 500, height: 200)
        )
        let lane = try #require(geometry.laneRect(trackIndex: 0, property: .opacity))
        let point = NSPoint(x: geometry.xForFrame(15), y: lane.midY)

        let hit = view.inputController.keyframeLaneHit(
            at: point,
            trackIndex: 0,
            property: .opacity,
            geometry: geometry
        )

        #expect(hit?.clipId == "clip")
        #expect(hit?.frame == 15)
    }
}
