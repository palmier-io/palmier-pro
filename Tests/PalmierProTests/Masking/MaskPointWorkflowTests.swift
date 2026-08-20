import Foundation
import Testing
@testable import PalmierPro

@Suite("Mask point workflow")
@MainActor
struct MaskPointWorkflowTests {
    @Test func escapeBeforeClickCreatesNoMask() {
        let editor = makeEditor()
        editor.beginMaskPointSelection(clipId: "clip")
        #expect(editor.maskPointSelectionClipId == "clip")
        editor.cancelMaskPointSelection()
        #expect(editor.maskPointSelectionClipId == nil)
        #expect(editor.clipFor(id: "clip")?.masks == nil)
    }

    @Test func clickCreatesOneUndoablePointMask() throws {
        let editor = makeEditor()
        let manager = UndoManager()
        editor.undo.attach(manager)
        editor.seekToFrame(10)
        editor.beginMaskPointSelection(clipId: "clip")
        try editor.commitMaskPointSelection(
            clipId: "clip",
            sourcePoint: CGPoint(x: 0.25, y: 0.75),
            canvasPoint: CGPoint(x: 0.25, y: 0.75)
        )

        let mask = try #require(editor.clipFor(id: "clip")?.masks?.first)
        guard case .point(let point) = mask.seed else {
            Issue.record("Expected point seed")
            return
        }
        #expect(point.x == 0.25)
        #expect(point.y == 0.75)
        #expect(manager.undoActionName == "Add Mask")

        _ = editor.undo.undoLatest()
        #expect(editor.clipFor(id: "clip")?.masks == nil)
        #expect(editor.maskPointMarker == nil)
    }

    private func makeEditor() -> EditorViewModel {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(
            fps: 30,
            tracks: [Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "clip", start: 0, duration: 60),
            ])]
        )
        return editor
    }
}
