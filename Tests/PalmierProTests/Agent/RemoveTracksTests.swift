import Foundation
import Testing
@testable import PalmierPro

@Suite("ToolExecutor — remove_tracks")
@MainActor
struct RemoveTracksTests {
    private func harness() -> ToolHarness {
        ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(label: "Captions", clips: (0..<50).map {
                Fixtures.clip(mediaType: .text, start: $0 * 10, duration: 10)
            }),
            Fixtures.videoTrack(label: "V1", clips: [Fixtures.clip(start: 0, duration: 100)]),
            Fixtures.audioTrack(label: "A1", clips: [Fixtures.clip(mediaType: .audio, start: 0, duration: 100)]),
        ]))
    }

    @Test func removesTrackWithAllItsClips() async throws {
        let h = harness()
        let result = try await h.runOK("remove_tracks", args: ["trackIndexes": [0]])

        let removed = try #require((result as? [String: Any])?["removedTracks"] as? [[String: Any]])
        #expect(removed.count == 1)
        #expect(removed.first?["clipCount"] as? Int == 50)
        #expect(h.editor.timeline.tracks.count == 2)
        #expect(h.editor.timeline.tracks.allSatisfy { $0.label != "Captions" })
    }

    @Test func removesMultipleTracksAndDedupesIndexes() async throws {
        let h = harness()
        _ = try await h.runOK("remove_tracks", args: ["trackIndexes": [0, 2, 0]])
        #expect(h.editor.timeline.tracks.count == 1)
        #expect(h.editor.timeline.tracks.first?.label == "V1")
    }

    @Test func rejectsOutOfRangeIndex() async throws {
        let h = harness()
        let result = await h.runRaw("remove_tracks", args: ["trackIndexes": [5]])
        #expect(result.isError == true)
        #expect(h.editor.timeline.tracks.count == 3)
    }

    @Test func rejectsEmptyIndexes() async throws {
        let h = harness()
        let result = await h.runRaw("remove_tracks", args: ["trackIndexes": [Int]()])
        #expect(result.isError == true)
    }
}
