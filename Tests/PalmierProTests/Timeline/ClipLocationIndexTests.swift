import Foundation
import Testing
@testable import PalmierPro

@Suite("EditorViewModel — clip location index")
@MainActor
struct ClipLocationIndexTests {

    private func editor() -> EditorViewModel {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "v1", start: 0, duration: 30),
                Fixtures.clip(id: "v2", start: 30, duration: 30),
            ]),
            Fixtures.audioTrack(clips: [Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 60)]),
        ])
        return e
    }

    @Test func findsClipsAcrossTracks() {
        let e = editor()
        #expect(e.findClip(id: "v2") == ClipLocation(trackIndex: 0, clipIndex: 1))
        #expect(e.findClip(id: "a1") == ClipLocation(trackIndex: 1, clipIndex: 0))
        #expect(e.findClip(id: "missing") == nil)
    }

    @Test func indexFollowsMutations() {
        let e = editor()
        _ = e.findClip(id: "v1")
        e.timeline.tracks[0].clips.remove(at: 0)
        #expect(e.findClip(id: "v1") == nil)
        #expect(e.findClip(id: "v2") == ClipLocation(trackIndex: 0, clipIndex: 0))
    }

    @Test func indexFollowsUndo() {
        let e = editor()
        let undoManager = UndoManager()
        e.undo.attach(undoManager)
        e.commitClipProperties(clipIds: ["v1"]) { $0.opacity = 0.5 }
        _ = e.findClip(id: "v1")
        undoManager.undo()
        #expect(e.clipFor(id: "v1")?.opacity == 1.0)
    }

    @Test func indexFollowsActiveTimelineSwitch() {
        let e = editor()
        _ = e.findClip(id: "v1")
        var second = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "other", start: 0, duration: 30)]),
        ])
        second.id = "second"
        e.timelines.append(second)
        e.activeTimelineId = "second"
        #expect(e.findClip(id: "v1") == nil)
        #expect(e.findClip(id: "other") == ClipLocation(trackIndex: 0, clipIndex: 0))
    }
}
