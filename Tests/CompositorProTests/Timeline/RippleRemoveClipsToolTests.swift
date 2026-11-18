import Foundation
import Testing
@testable import CompositorPro

@Suite("Ripple remove_clips wiring")
@MainActor
struct RippleRemoveClipsToolTests {
    private func harness() -> ToolHarness {
        let harness = ToolHarness()
        harness.editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "a", start: 0, duration: 30),
                Fixtures.clip(id: "b", start: 30, duration: 30),
                Fixtures.clip(id: "c", start: 60, duration: 30),
            ]),
        ])
        return harness
    }

    private func start(_ harness: ToolHarness, _ id: String) -> Int? {
        harness.editor.findClip(id: id).map { harness.editor.timeline.tracks[$0.trackIndex].clips[$0.clipIndex].startFrame }
    }

    @Test func defaultRemovalKeepsPositions() async throws {
        let harness = harness()
        _ = try await harness.runOK("remove_clips", args: ["clipIds": ["b"]])
        #expect(harness.editor.findClip(id: "b") == nil)
        #expect(start(harness, "c") == 60)
    }

    @Test func rippleRemovalClosesTheVacatedRange() async throws {
        let harness = harness()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)

        _ = try await harness.runOK("remove_clips", args: ["clipIds": ["b"], "ripple": true])
        #expect(harness.editor.findClip(id: "b") == nil)
        #expect(start(harness, "a") == 0)
        #expect(start(harness, "c") == 30)

        undo.undo()
        #expect(start(harness, "b") == 30)
        #expect(start(harness, "c") == 60)
    }
}
