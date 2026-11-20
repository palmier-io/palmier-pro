import Foundation
import Testing
@testable import CompositorPro

@Suite("Transcript import placement")
@MainActor
struct TranscriptImportPlacementTests {
    @Test func importedSegmentsBecomeOneUndoableCaptionGroup() {
        let harness = ToolHarness()
        harness.editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [])])
        harness.editor.timeline.fps = 30
        let undo = UndoManager()
        harness.editor.undo.attach(undo)

        let ids = harness.editor.importTranscriptSegments([
            TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "First"),
            TranscriptSegment(startSeconds: 1, endSeconds: 2.5, text: "Second"),
        ])
        #expect(ids.count == 2)

        let clips = harness.editor.timeline.tracks.flatMap(\.clips).filter { ids.contains($0.id) }
        #expect(clips.count == 2)
        #expect(clips.map(\.startFrame).sorted() == [0, 30])
        #expect(Set(clips.compactMap(\.captionGroupId)).count == 1)
        #expect(clips.contains { $0.textContent == "Second" })

        undo.undo()
        #expect(harness.editor.timeline.tracks.flatMap(\.clips).filter { ids.contains($0.id) }.isEmpty)
    }

    @Test func emptyTranscriptAddsNothing() {
        let harness = ToolHarness()
        harness.editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [])])
        let before = harness.editor.timeline
        #expect(harness.editor.importTranscriptSegments([]).isEmpty)
        #expect(harness.editor.timeline == before)
    }
}
