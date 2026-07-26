import Foundation
import Testing
@testable import PalmierPro

/// Slip edits shift the source in/out window while the clip's timeline footprint stays fixed.
@MainActor
private func editor(_ tracks: [Track] = []) -> EditorViewModel {
    let e = EditorViewModel()
    e.timeline = Fixtures.timeline(tracks: tracks)
    return e
}

@Suite("EditorViewModel — commitSlip")
@MainActor
struct SlipTests {

    @Test func slipRightRevealsEarlierMaterial() {
        let clip = Fixtures.clip(id: "c1", start: 100, duration: 60, trimStart: 30, trimEnd: 20)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.commitSlip(clipId: "c1", deltaFrames: 10, propagateToLinked: true)
        let updated = e.timeline.tracks[0].clips[0]
        #expect(updated.trimStartFrame == 20)
        #expect(updated.trimEndFrame == 30)
        #expect(updated.startFrame == 100)
        #expect(updated.durationFrames == 60)
        #expect(updated.sourceDurationFrames == clip.sourceDurationFrames)
    }

    @Test func slipLeftRevealsLaterMaterial() {
        let clip = Fixtures.clip(id: "c1", start: 100, duration: 60, trimStart: 30, trimEnd: 20)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.commitSlip(clipId: "c1", deltaFrames: -10, propagateToLinked: true)
        let updated = e.timeline.tracks[0].clips[0]
        #expect(updated.trimStartFrame == 40)
        #expect(updated.trimEndFrame == 10)
    }

    @Test func slipClampsAtHeadMaterial() {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 60, trimStart: 5, trimEnd: 20)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.commitSlip(clipId: "c1", deltaFrames: 30, propagateToLinked: true)
        let updated = e.timeline.tracks[0].clips[0]
        #expect(updated.trimStartFrame == 0)
        #expect(updated.trimEndFrame == 25)
    }

    @Test func slipClampsAtTailMaterial() {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 60, trimStart: 20, trimEnd: 5)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.commitSlip(clipId: "c1", deltaFrames: -30, propagateToLinked: true)
        let updated = e.timeline.tracks[0].clips[0]
        #expect(updated.trimStartFrame == 25)
        #expect(updated.trimEndFrame == 0)
    }

    @Test func slipScalesTimelineDeltaThroughSpeed() {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 60, trimStart: 40, trimEnd: 40, speed: 2.0)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.commitSlip(clipId: "c1", deltaFrames: 10, propagateToLinked: true)
        let updated = e.timeline.tracks[0].clips[0]
        #expect(updated.trimStartFrame == 20)
        #expect(updated.trimEndFrame == 60)
    }

    @Test func slipSpeedAwareClampKeepsTrimsNonNegative() {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 60, trimStart: 10, trimEnd: 40, speed: 2.0)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.commitSlip(clipId: "c1", deltaFrames: 10, propagateToLinked: true)
        let updated = e.timeline.tracks[0].clips[0]
        #expect(updated.trimStartFrame == 0)
        #expect(updated.trimEndFrame == 50)
    }

    @Test func slipPropagatesToLinkedPartnerAndTightestHeadroomWins() {
        var v = Fixtures.clip(id: "v1", start: 0, duration: 60, trimStart: 30, trimEnd: 30)
        var a = Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 60, trimStart: 8, trimEnd: 30)
        v.linkGroupId = "g1"
        a.linkGroupId = "g1"
        let e = editor([Fixtures.videoTrack(clips: [v]), Fixtures.audioTrack(clips: [a])])
        e.commitSlip(clipId: "v1", deltaFrames: 20, propagateToLinked: true)
        let video = e.timeline.tracks[0].clips[0]
        let audio = e.timeline.tracks[1].clips[0]
        #expect(video.trimStartFrame == 22)
        #expect(video.trimEndFrame == 38)
        #expect(audio.trimStartFrame == 0)
        #expect(audio.trimEndFrame == 38)
    }

    @Test func slipWithoutPropagationMovesOnlyLead() {
        var v = Fixtures.clip(id: "v1", start: 0, duration: 60, trimStart: 30, trimEnd: 30)
        var a = Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 60, trimStart: 30, trimEnd: 30)
        v.linkGroupId = "g1"
        a.linkGroupId = "g1"
        let e = editor([Fixtures.videoTrack(clips: [v]), Fixtures.audioTrack(clips: [a])])
        e.commitSlip(clipId: "v1", deltaFrames: 10, propagateToLinked: false)
        #expect(e.timeline.tracks[0].clips[0].trimStartFrame == 20)
        #expect(e.timeline.tracks[1].clips[0].trimStartFrame == 30)
    }

    @Test func slipRefusesMulticamAndImageClips() {
        var mc = Fixtures.clip(id: "mc", start: 0, duration: 60, trimStart: 30, trimEnd: 30)
        mc.multicamGroupId = "group"
        let img = Fixtures.clip(id: "img", mediaType: .image, start: 100, duration: 60)
        let e = editor([Fixtures.videoTrack(clips: [mc, img])])
        e.commitSlip(clipId: "mc", deltaFrames: 10, propagateToLinked: true)
        e.commitSlip(clipId: "img", deltaFrames: 10, propagateToLinked: true)
        #expect(e.timeline.tracks[0].clips[0].trimStartFrame == 30)
        #expect(e.timeline.tracks[0].clips[1].trimStartFrame == 0)
    }

    @Test func slipUndoRestoresOriginalTrims() {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 60, trimStart: 30, trimEnd: 20)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        let undoManager = UndoManager()
        e.undo.attach(undoManager)
        e.commitSlip(clipId: "c1", deltaFrames: 10, propagateToLinked: true)
        #expect(e.timeline.tracks[0].clips[0].trimStartFrame == 20)
        undoManager.undo()
        let restored = e.timeline.tracks[0].clips[0]
        #expect(restored.trimStartFrame == 30)
        #expect(restored.trimEndFrame == 20)
    }

    @Test func slipLeavesKeyframesUntouched() {
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 60, trimStart: 30, trimEnd: 20)
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 1.0),
            Keyframe(frame: 30, value: 0.5),
        ])
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.commitSlip(clipId: "c1", deltaFrames: 10, propagateToLinked: true)
        #expect(e.timeline.tracks[0].clips[0].opacityTrack?.keyframes.map(\.frame) == [0, 30])
    }

    @Test func slipZeroDeltaIsNoOp() {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 60, trimStart: 30, trimEnd: 20)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        let undoManager = UndoManager()
        e.undo.attach(undoManager)
        e.commitSlip(clipId: "c1", deltaFrames: 0, propagateToLinked: true)
        #expect(undoManager.canUndo == false)
        #expect(e.timeline.tracks[0].clips[0].trimStartFrame == 30)
    }
}
