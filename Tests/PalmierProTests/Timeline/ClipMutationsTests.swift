import Foundation
import Testing
@testable import PalmierPro

/// Direct tests against EditorViewModel's clip-mutation APIs
@MainActor
private func editor(_ tracks: [Track] = []) -> EditorViewModel {
    let e = EditorViewModel()
    e.timeline = Fixtures.timeline(tracks: tracks)
    return e
}

@Suite("EditorViewModel — applyClipSpeed")
@MainActor
struct ApplyClipSpeedTests {

    @Test func applyClipSpeedDoublesScalesDurationDownByHalf() {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.applyClipSpeed(clipId: "c1", newSpeed: 2.0)
        let updated = e.timeline.tracks[0].clips[0]
        #expect(updated.speed == 2.0)
        // sourceFrames=60*1=60; newDuration = 60/2 = 30.
        #expect(updated.durationFrames == 30)
    }

    @Test func applyClipSpeedHalfDoublesDuration() {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.applyClipSpeed(clipId: "c1", newSpeed: 0.5)
        #expect(e.timeline.tracks[0].clips[0].durationFrames == 120)
    }

    @Test func applyClipSpeedRipplesContiguousChainOnSameTrack() {
        // Two clips touching at frame 60: c1 [0, 60), c2 [60, 90).
        // Speeding c1 to 2.0 shrinks it to [0, 30) → contiguous c2 should ripple to [30, 60).
        let c1 = Fixtures.clip(id: "c1", start: 0, duration: 60)
        let c2 = Fixtures.clip(id: "c2", start: 60, duration: 30)
        let e = editor([Fixtures.videoTrack(clips: [c1, c2])])
        e.applyClipSpeed(clipId: "c1", newSpeed: 2.0)
        let updated = e.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
        #expect(updated[0].durationFrames == 30)
        #expect(updated[1].startFrame == 30)
    }

    @Test func applyClipSpeedDoesNotRippleNonContiguousFollowers() {
        // c2 has a gap before it → not part of the contiguous chain, should not move.
        let c1 = Fixtures.clip(id: "c1", start: 0, duration: 60)
        let c2 = Fixtures.clip(id: "c2", start: 100, duration: 30)
        let e = editor([Fixtures.videoTrack(clips: [c1, c2])])
        e.applyClipSpeed(clipId: "c1", newSpeed: 2.0)
        let updated = e.timeline.tracks[0].clips.first { $0.id == "c2" }!
        #expect(updated.startFrame == 100)
    }

    @Test func applyClipSpeedRescalesKeyframesInsteadOfDroppingThem() {
        // 2x speed halves a 60-frame clip; keyframes must rescale, not get clamped away.
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 1.0),
            Keyframe(frame: 30, value: 0.5),
            Keyframe(frame: 60, value: 0.0),
        ])
        clip.scaleTrack = KeyframeTrack(keyframes: [Keyframe(frame: 60, value: AnimPair(a: 2.0, b: 2.0))])
        let e = editor([Fixtures.videoTrack(clips: [clip])])

        e.applyClipSpeed(clipId: "c1", newSpeed: 2.0)
        let updated = e.timeline.tracks[0].clips[0]

        #expect(updated.durationFrames == 30)
        #expect(updated.opacityTrack?.keyframes.map(\.frame) == [0, 15, 30])
        #expect(updated.scaleTrack?.keyframes.map(\.frame) == [30])
    }
}

@Suite("EditorViewModel — splitClip")
@MainActor
struct SplitClipTests {

    @Test func splitClipDividesAtFrameAndReturnsRightHalfId() {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        let rightIds = e.splitClip(clipId: "c1", atFrame: 30)
        #expect(rightIds.count == 1)
        let clips = e.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
        #expect(clips.count == 2)
        #expect(clips[0].durationFrames == 30)
        #expect(clips[1].durationFrames == 30)
        #expect(clips[1].id == rightIds[0])
    }

    @Test func splitClipReturnsEmptyForUnknownId() {
        let e = editor()
        #expect(e.splitClip(clipId: "ghost", atFrame: 10).isEmpty)
    }

    @Test func splitAtClipBoundaryIsRejected() {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        // atFrame must be strictly inside (clip.startFrame, clip.endFrame).
        #expect(e.splitClip(clipId: "c1", atFrame: 0).isEmpty)
        #expect(e.splitClip(clipId: "c1", atFrame: 60).isEmpty)
        // Verify the clip was not modified.
        #expect(e.timeline.tracks[0].clips.count == 1)
    }

    @Test func splitClipDoesNotCutAnotherClipOnSameTrack() {
        // c1 = 0..30, c2 = 30..60. Splitting c1 at frame 45 (inside c2, outside c1) must
        // do nothing — not resolve to c2 and cut it.
        let e = editor([Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "c1", start: 0, duration: 30),
            Fixtures.clip(id: "c2", start: 30, duration: 30),
        ])])
        #expect(e.splitClip(clipId: "c1", atFrame: 45).isEmpty)
        #expect(e.timeline.tracks[0].clips.count == 2)
    }

    @Test func splitWithLinkedPartnerSplitsBothAndRegroupsRightHalves() {
        // video + audio sharing g1. After split at 30, the right halves should share a
        // *new* group id (not the original g1).
        var v = Fixtures.clip(id: "v", start: 0, duration: 60)
        v.linkGroupId = "g1"
        var a = Fixtures.clip(id: "a", mediaType: .audio, start: 0, duration: 60)
        a.linkGroupId = "g1"

        let e = editor([
            Fixtures.videoTrack(clips: [v]),
            Fixtures.audioTrack(clips: [a]),
        ])
        let rightIds = Set(e.splitClip(clipId: "v", atFrame: 30))
        #expect(rightIds.count == 2, "both partners should split")

        let allClips = e.timeline.tracks.flatMap(\.clips)
        // The two right halves share a single group id, distinct from "g1".
        let rightGroups = Set(allClips.filter { rightIds.contains($0.id) }.compactMap(\.linkGroupId))
        #expect(rightGroups.count == 1)
        #expect(rightGroups.first != "g1")

        // The two left halves still share the original group.
        let leftIds: Set<String> = ["v", "a"]
        let leftGroups = Set(allClips.filter { leftIds.contains($0.id) }.compactMap(\.linkGroupId))
        #expect(leftGroups == ["g1"])
    }

    @Test func splitClipsAtMultiplePointsCutsEachAndSkipsBoundaries() {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 90)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        // Two real cuts plus a repeat of the first: the repeat lands on a boundary and is a no-op.
        let rightIds = e.splitClips(at: [(0, 30), (0, 60), (0, 30)])
        let clips = e.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
        #expect(clips.map(\.startFrame) == [0, 30, 60])
        #expect(clips.map(\.durationFrames) == [30, 30, 30])
        #expect(rightIds.count == 2)
    }

    @Test func splitClipKeepsSegmentInterpolationOnRightHalf() {
        // hold opacity (0→1.0) and linear rotation (0°→20°). Splitting mid-segment must not
        // turn the right half's opening keyframe smooth: hold stays flat, linear stays straight.
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 1.0, interpolationOut: .hold),
            Keyframe(frame: 30, value: 0.5),
        ])
        clip.rotationTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0.0, interpolationOut: .linear),
            Keyframe(frame: 20, value: 20.0),
        ])
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        let rightId = e.splitClip(clipId: "c1", atFrame: 10)[0]
        let right = e.timeline.tracks[0].clips.first { $0.id == rightId }!
        #expect(right.opacityTrack?.sample(at: 5, fallback: 0.0) == 1.0)   // hold: still flat
        #expect(right.rotationTrack?.sample(at: 5, fallback: 0.0) == 15.0) // linear: 10°→20° at halfway
    }

    @Test func splitClipZerosOpacityFadesAcrossCut() {
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        clip.fadeInFrames = 15
        clip.fadeOutFrames = 20
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        _ = e.splitClip(clipId: "c1", atFrame: 30)
        let halves = e.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
        #expect(halves.count == 2)
        #expect(halves[0].fadeInFrames == 15)
        #expect(halves[0].fadeOutFrames == 0)
        #expect(halves[1].fadeInFrames == 0)
        #expect(halves[1].fadeOutFrames == 20)
    }
}

@Suite("EditorViewModel — applyTimelineSettings")
@MainActor
struct ApplyTimelineSettingsTests {

    @Test func rescalesOpacityFadesByFpsRatio() {
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        clip.fadeInFrames = 30
        clip.fadeOutFrames = 30
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.applyTimelineSettings(fps: 60, width: 1920, height: 1080)
        let updated = e.timeline.tracks[0].clips[0]
        #expect(updated.fadeInFrames == 60)
        #expect(updated.fadeOutFrames == 60)
    }

    @Test func rescalesAllKeyframeTracksByFpsRatio() {
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        clip.opacityTrack = KeyframeTrack(keyframes: [Keyframe(frame: 15, value: 0.5)])
        clip.positionTrack = KeyframeTrack(keyframes: [Keyframe(frame: 15, value: AnimPair(a: 0.1, b: 0.2))])
        clip.scaleTrack = KeyframeTrack(keyframes: [Keyframe(frame: 15, value: AnimPair(a: 0.5, b: 0.5))])
        clip.rotationTrack = KeyframeTrack(keyframes: [Keyframe(frame: 15, value: 45)])
        clip.cropTrack = KeyframeTrack(keyframes: [Keyframe(frame: 15, value: Crop(left: 0.1, top: 0, right: 0, bottom: 0))])
        clip.volumeTrack = KeyframeTrack(keyframes: [Keyframe(frame: 15, value: -6)])

        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.applyTimelineSettings(fps: 60, width: 1920, height: 1080)
        let updated = e.timeline.tracks[0].clips[0]

        #expect(updated.durationFrames == 120)
        #expect(updated.opacityTrack?.keyframes.map(\.frame) == [30])
        #expect(updated.positionTrack?.keyframes.map(\.frame) == [30])
        #expect(updated.scaleTrack?.keyframes.map(\.frame) == [30])
        #expect(updated.rotationTrack?.keyframes.map(\.frame) == [30])
        #expect(updated.cropTrack?.keyframes.map(\.frame) == [30])
        #expect(updated.volumeTrack?.keyframes.map(\.frame) == [30])
    }

    @Test func fpsRetimeDedupesRoundedKeyframesLastValueWins() {
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 20)
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 1, value: 0.2),
            Keyframe(frame: 2, value: 0.8),
        ])

        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.applyTimelineSettings(fps: 15, width: 1920, height: 1080)
        let kfs = e.timeline.tracks[0].clips[0].opacityTrack?.keyframes ?? []

        #expect(kfs.map(\.frame) == [1])
        #expect(kfs.first?.value == 0.8)
    }

    @Test func fpsRetimeKeepsSameTrackClipsNonOverlappingAfterRounding() {
        let first = Fixtures.clip(id: "c1", start: 2, duration: 1)
        let second = Fixtures.clip(id: "c2", start: 3, duration: 1)
        let e = editor([Fixtures.videoTrack(clips: [first, second])])

        e.applyTimelineSettings(fps: 12, width: 1920, height: 1080)
        let clips = e.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }

        #expect(clips[0].endFrame <= clips[1].startFrame)
    }
}

@Suite("EditorViewModel — stampKeyframe")
@MainActor
struct StampKeyframeTests {

    @Test func opacityStoresAuthoredValueNotFadedValue() {
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 100)
        clip.opacity = 1.0
        clip.fadeInFrames = 10
        clip.fadeInInterpolation = .linear
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.stampKeyframe(clipId: "c1", property: .opacity, frame: 5)
        let kf = e.timeline.tracks[0].clips[0].opacityTrack?.keyframes.first
        #expect(kf?.frame == 5)
        #expect(kf?.value == 1.0)
    }
}

@Suite("EditorViewModel — removeClips")
@MainActor
struct RemoveClipsTests {

    @Test func removeClipsPrunesEmptyTracksByDefault() {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 30)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.removeClips(ids: ["c1"])
        #expect(e.timeline.tracks.isEmpty)
    }

    @Test func removeClipsWithPruneFalseKeepsEmptyTracks() {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 30)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.removeClips(ids: ["c1"], prune: false)
        #expect(e.timeline.tracks.count == 1)
        #expect(e.timeline.tracks[0].clips.isEmpty)
    }

    @Test func removeClipsIsNoOpForUnknownIds() {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 30)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.removeClips(ids: ["ghost"])
        #expect(e.timeline.tracks[0].clips.count == 1)
    }

    @Test func removeClipsAlsoClearsSelection() {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 30)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.selectedClipIds = ["c1", "ghost"]
        e.removeClips(ids: ["c1"])
        // c1 dropped from selection; "ghost" was never a real clip but also dropped since
        // selection subtract is set-based, not membership-checked.
        #expect(!e.selectedClipIds.contains("c1"))
    }
}

@Suite("EditorViewModel — moveClips")
@MainActor
struct MoveClipsTests {

    @Test func moveClipsMovesSingleClipToTargetTrackAndFrame() {
        let c1 = Fixtures.clip(id: "c1", start: 0, duration: 30)
        let e = editor([
            Fixtures.videoTrack(clips: [c1]),
            Fixtures.videoTrack(clips: []),
        ])
        let destTrackId = e.timeline.tracks[1].id
        e.moveClips([(clipId: "c1", toTrack: 1, toFrame: 100)])
        let loc = e.findClip(id: "c1")!
        #expect(e.timeline.tracks[loc.trackIndex].id == destTrackId)
        #expect(e.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].startFrame == 100)
    }

    @Test func moveClipsRejectsIncompatibleTrackType() {
        // Moving a video clip onto an audio track is silently skipped (type mismatch).
        let c1 = Fixtures.clip(id: "c1", start: 0, duration: 30)
        let e = editor([
            Fixtures.videoTrack(clips: [c1]),
            Fixtures.audioTrack(clips: []),
        ])
        e.moveClips([(clipId: "c1", toTrack: 1, toFrame: 100)])
        let loc = e.findClip(id: "c1")!
        // Clip stayed on the original (video) track.
        #expect(e.timeline.tracks[loc.trackIndex].type == .video)
    }

    @Test func moveClipsClampsNegativeFrameToZero() {
        let c1 = Fixtures.clip(id: "c1", start: 0, duration: 30)
        let e = editor([
            Fixtures.videoTrack(clips: [c1]),
            Fixtures.videoTrack(clips: []),
        ])
        e.moveClips([(clipId: "c1", toTrack: 1, toFrame: -50)])
        let loc = e.findClip(id: "c1")!
        #expect(e.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].startFrame == 0)
    }
}

@Suite("EditorViewModel — writePosition")
@MainActor
struct WritePositionTests {

    @Test func writePositionWithActiveKeyframesPreservesFallbackTransform() {
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        clip.transform.centerX = 0.5
        clip.transform.centerY = 0.5
        clip.transform.width = 0.4
        clip.transform.height = 0.4
        clip.positionTrack = KeyframeTrack(keyframes: [Keyframe(frame: 0, value: AnimPair(a: 0.1, b: 0.1))])

        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.currentFrame = 0

        e.commitPosition(clipId: "c1", setX: 0.4, setY: 0.4)

        let updated = e.timeline.tracks[0].clips[0]
        let kf = updated.positionTrack?.keyframes.first(where: { $0.frame == 0 })
        #expect(kf?.value == AnimPair(a: 0.4, b: 0.4))
        // Fallback transform must not be touched while keyframes are active.
        // Bug: without the else-guard, centerX/Y become 0.6 (0.4 + width/2).
        #expect(updated.transform.centerX == 0.5)
        #expect(updated.transform.centerY == 0.5)
    }

    @Test func batchPositionUpdatesAllClips() {
        var a = Fixtures.clip(id: "a", start: 0, duration: 60)
        var b = Fixtures.clip(id: "b", start: 10, duration: 60)
        a.transform.width = 0.2
        a.transform.height = 0.2
        b.transform.width = 0.4
        b.transform.height = 0.4

        let e = editor([Fixtures.videoTrack(clips: [a, b])])
        e.currentFrame = 0

        e.commitPositions(clipIds: ["a", "b"], setX: 0.3, setY: 0.4)

        let updated = e.timeline.tracks[0].clips
        #expect(abs(updated[0].topLeftAt(frame: 0).x - 0.3) < 0.000001)
        #expect(abs(updated[0].topLeftAt(frame: 0).y - 0.4) < 0.000001)
        #expect(abs(updated[1].topLeftAt(frame: 0).x - 0.3) < 0.000001)
        #expect(abs(updated[1].topLeftAt(frame: 0).y - 0.4) < 0.000001)
    }
}

@Suite("EditorViewModel — clip property commits")
@MainActor
struct ClipPropertyCommitTests {

    @Test func commitClipPropertiesGroupsMultipleClipUndo() {
        var a = Fixtures.clip(id: "a", mediaRef: "text", mediaType: .text, start: 0, duration: 30)
        var b = Fixtures.clip(id: "b", mediaRef: "text", mediaType: .text, start: 30, duration: 30)
        a.textContent = "one"
        b.textContent = "two"
        let e = editor([Fixtures.videoTrack(clips: [a, b])])
        let undoManager = UndoManager()
        e.undoManager = undoManager

        e.commitClipProperties(clipIds: ["a", "b"]) {
            $0.textAnimation = TextAnimation(preset: .wordPop)
        }

        #expect(e.timeline.tracks[0].clips.allSatisfy { $0.textAnimation?.preset == .wordPop })
        undoManager.undo()
        #expect(e.timeline.tracks[0].clips.allSatisfy { $0.textAnimation == nil })
        #expect(undoManager.canUndo == false)
    }

    @Test func cancelDebouncedCommitPreventsPendingHighlightWrite() async throws {
        var clip = Fixtures.clip(id: "caption", mediaRef: "text", mediaType: .text, start: 0, duration: 30)
        clip.textAnimation = TextAnimation(preset: .highlightPop, highlight: .init(r: 1, g: 0, b: 0, a: 1))
        let e = editor([Fixtures.videoTrack(clips: [clip])])

        e.debouncedCommitClipProperties(clipIds: ["caption"], key: "textHighlight", debounce: .milliseconds(5)) {
            var animation = $0.textAnimation ?? TextAnimation()
            animation.highlight = .init(r: 0, g: 0, b: 1, a: 1)
            $0.textAnimation = animation
        }
        e.cancelDebouncedCommit(key: "textHighlight")
        e.commitClipProperties(clipIds: ["caption"]) {
            $0.textAnimation = nil
        }

        try await Task.sleep(for: .milliseconds(20))
        #expect(e.timeline.tracks[0].clips[0].textAnimation == nil)
    }
}

@Suite("EditorViewModel — clearRegion")
@MainActor
struct ClearRegionTests {

    @Test func clearRegionRemovesClipFullyInside() {
        let inside = Fixtures.clip(id: "inside", start: 50, duration: 30) // [50, 80)
        let e = editor([Fixtures.videoTrack(clips: [inside])])
        e.clearRegion(trackIndex: 0, start: 0, end: 100)
        #expect(e.timeline.tracks.isEmpty || e.timeline.tracks[0].clips.isEmpty)
    }

    @Test func clearRegionTrimsLeftOverlapper() {
        // Clip [0, 100) with region [50, 200) → trim end so clip becomes [0, 50).
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 100)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.clearRegion(trackIndex: 0, start: 50, end: 200)
        let remaining = e.timeline.tracks[0].clips[0]
        #expect(remaining.startFrame == 0)
        #expect(remaining.durationFrames == 50)
    }

    @Test func clearRegionTrimsRightOverlapper() {
        // Clip [100, 200) with region [0, 150) → trim start so clip becomes [150, 200).
        let clip = Fixtures.clip(id: "c1", start: 100, duration: 100)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.clearRegion(trackIndex: 0, start: 0, end: 150)
        let remaining = e.timeline.tracks[0].clips[0]
        #expect(remaining.startFrame == 150)
        #expect(remaining.durationFrames == 50)
    }

    @Test func clearRegionLeavesAdjacentClipUntouched() {
        // Half-open boundary: clip starts exactly at regionEnd → not touched.
        let clip = Fixtures.clip(id: "c1", start: 100, duration: 30)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.clearRegion(trackIndex: 0, start: 0, end: 100)
        #expect(e.timeline.tracks[0].clips[0].startFrame == 100)
        #expect(e.timeline.tracks[0].clips[0].durationFrames == 30)
    }
}
