import Foundation
import Testing
@testable import PalmierPro

@Suite("EditorViewModel — rotation mutation")
@MainActor
struct RotationMutationTests {
    @Test func batchRotationCommitUndoesAllClipsTogether() {
        let editor = EditorViewModel()
        let undoManager = UndoManager()
        editor.undo.attach(undoManager)
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "first", start: 0, duration: 20),
                Fixtures.clip(id: "second", start: 20, duration: 20),
            ]),
        ])

        editor.applyRotation(clipIds: ["first", "second"], valueDeg: 90)
        editor.commitRotation(clipIds: ["first", "second"], valueDeg: 90)

        #expect(editor.clipFor(id: "first")?.transform.rotation == 90)
        #expect(editor.clipFor(id: "second")?.transform.rotation == 90)
        #expect(editor.undo.undoLatest() == "Change Rotation")
        #expect(editor.clipFor(id: "first")?.transform.rotation == 0)
        #expect(editor.clipFor(id: "second")?.transform.rotation == 0)
        #expect(!undoManager.canUndo)
    }

    @Test func batchRotationWritesActiveKeyframeTracks() throws {
        let editor = EditorViewModel()
        var staticClip = Fixtures.clip(id: "static", start: 0, duration: 20)
        var animatedClip = Fixtures.clip(id: "animated", start: 0, duration: 20)
        animatedClip.rotationTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0),
        ])
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [staticClip]),
            Fixtures.videoTrack(clips: [animatedClip]),
        ])
        editor.currentFrame = 10

        editor.applyRotation(clipIds: ["static", "animated"], valueDeg: 45)
        editor.commitRotation(clipIds: ["static", "animated"], valueDeg: 45)

        staticClip = try #require(editor.clipFor(id: "static"))
        animatedClip = try #require(editor.clipFor(id: "animated"))
        #expect(staticClip.transform.rotation == 45)
        #expect(staticClip.rotationTrack == nil)
        #expect(animatedClip.transform.rotation == 0)
        #expect(animatedClip.rotationAt(frame: 10) == 45)
    }
}
