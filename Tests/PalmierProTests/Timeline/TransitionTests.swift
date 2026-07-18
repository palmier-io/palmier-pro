import Foundation
import Testing
@testable import PalmierPro

@Suite("Clip transitions")
struct TransitionTests {

    @Test func registryIncludesCommonTypes() {
        for id in [
            "dissolve", "fade.black",
            "wipe.left", "wipe.right", "wipe.up", "wipe.down",
            "push.left", "push.right", "push.up", "push.down",
            "zoom.in", "zoom.out",
            "flash.white",
        ] {
            #expect(TransitionRegistry.contains(id), "missing \(id)")
        }
        #expect(!TransitionRegistry.contains("nope"))
    }

    @Test func validTransitionRequiresExactOverlap() {
        let a = Fixtures.clip(id: "a", start: 0, duration: 100)
        var b = Fixtures.clip(id: "b", start: 80, duration: 100)
        b.transition = ClipTransition(type: "dissolve", durationFrames: 20)
        #expect(Clip.hasValidTransition(outgoing: a, incoming: b))

        b.startFrame = 90
        #expect(!Clip.hasValidTransition(outgoing: a, incoming: b))

        b.startFrame = 80
        b.transition = ClipTransition(type: "nope", durationFrames: 20)
        #expect(!Clip.hasValidTransition(outgoing: a, incoming: b))
    }

    @Test func abuttingClipsHaveZeroOverlap() {
        let a = Fixtures.clip(id: "a", start: 0, duration: 100)
        let b = Fixtures.clip(id: "b", start: 100, duration: 100)
        #expect(Clip.overlapFrames(outgoing: a, incoming: b) == 0)
    }
}

@MainActor
@Suite("EditorViewModel transitions")
struct EditorTransitionTests {

    private func editor(clips: [Clip]) -> EditorViewModel {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: clips)])
        editor.undo.attach(UndoManager())
        return editor
    }

    @Test func applyCreatesOverlapAndStoresTransition() throws {
        let a = Fixtures.clip(id: "a", start: 0, duration: 100)
        let b = Fixtures.clip(id: "b", start: 100, duration: 100)
        let c = Fixtures.clip(id: "c", start: 200, duration: 100)
        let editor = editor(clips: [a, b, c])

        try editor.applyTransition(outgoingId: "a", incomingId: "b", type: "wipe.left", durationFrames: 20)

        let clips = editor.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
        #expect(clips.map(\.id) == ["a", "b", "c"])
        #expect(clips[0].endFrame == 100)
        #expect(clips[1].startFrame == 80)
        #expect(clips[1].transition?.type == "wipe.left")
        #expect(clips[1].transition?.durationFrames == 20)
        #expect(clips[2].startFrame == 180)
        #expect(Clip.hasValidTransition(outgoing: clips[0], incoming: clips[1]))
    }

    @Test func removeRestoresAbuttingCut() throws {
        let a = Fixtures.clip(id: "a", start: 0, duration: 100)
        let b = Fixtures.clip(id: "b", start: 100, duration: 100)
        let editor = editor(clips: [a, b])
        try editor.applyTransition(outgoingId: "a", incomingId: "b", type: "dissolve", durationFrames: 15)
        try editor.removeTransition(incomingId: "b")

        let clips = editor.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
        #expect(clips[1].startFrame == 100)
        #expect(clips[1].transition == nil)
        #expect(clips[0].endFrame == clips[1].startFrame)
    }

    @Test func rejectsUnknownTypeAndNonAdjacent() {
        let a = Fixtures.clip(id: "a", start: 0, duration: 100)
        let b = Fixtures.clip(id: "b", start: 120, duration: 100)
        let editor = editor(clips: [a, b])

        #expect(throws: TransitionError.self) {
            try editor.applyTransition(outgoingId: "a", incomingId: "b", type: "dissolve", durationFrames: 10)
        }
        #expect(throws: TransitionError.self) {
            try editor.applyTransition(outgoingId: "a", incomingId: "b", type: "nope", durationFrames: 10)
        }
    }

    @Test func defaultDurationIsHalfSecond() {
        let editor = EditorViewModel()
        editor.timeline.fps = 30
        #expect(editor.defaultTransitionDurationFrames() == 15)
        editor.timeline.fps = 24
        #expect(editor.defaultTransitionDurationFrames() == 12)
    }
}
