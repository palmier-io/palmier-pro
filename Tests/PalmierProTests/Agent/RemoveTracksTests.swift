import Foundation
import Testing
@testable import PalmierPro

@Suite("ToolExecutor — remove_tracks")
@MainActor
struct RemoveTracksTests {
    private func captionClip(id: String = "caption-1") -> Clip {
        var clip = Fixtures.clip(id: id, mediaType: .text, start: 0, duration: 30)
        clip.captionGroupId = "captions-1"
        return clip
    }

    private func harness() -> ToolHarness {
        ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: (0..<50).map {
                Fixtures.clip(mediaType: .text, start: $0 * 10, duration: 10)
            }),
            Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 100)]),
            Fixtures.audioTrack(clips: [Fixtures.clip(mediaType: .audio, start: 0, duration: 100)]),
        ]))
    }

    @Test func removesTrackWithAllItsClips() async throws {
        let h = harness()
        let result = try await h.runOK("remove_tracks", args: ["trackIndexes": [0]])

        let removed = try #require((result as? [String: Any])?["removedTracks"] as? [[String: Any]])
        #expect(removed.count == 1)
        #expect(removed.first?["clipCount"] as? Int == 50)
        #expect(h.editor.timeline.tracks.count == 2)
        #expect(h.editor.timeline.tracks.allSatisfy { track in !track.clips.contains { $0.mediaType == .text } })
    }

    @Test func removesMultipleTracksAndDedupesIndexes() async throws {
        let h = harness()
        _ = try await h.runOK("remove_tracks", args: ["trackIndexes": [0, 2, 0]])
        #expect(h.editor.timeline.tracks.count == 1)
        #expect(h.editor.timelineTrackDisplayLabel(at: 0) == "V1")
    }

    @Test func rejectsCaptionTrackByDefault() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [captionClip()]),
            Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 100)]),
        ]))
        let result = await h.runRaw("remove_tracks", args: ["trackIndexes": [0]])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("contains captions"))
        #expect(h.editor.timeline.tracks.count == 2)
    }

    @Test func removesCaptionTrackWhenExplicit() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [captionClip()]),
            Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 100)]),
        ]))
        _ = try await h.runOK("remove_tracks", args: ["trackIndexes": [0], "includeCaptions": true])
        #expect(h.editor.timeline.tracks.count == 1)
        #expect(h.editor.timeline.tracks[0].clips.allSatisfy { $0.captionGroupId == nil })
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
