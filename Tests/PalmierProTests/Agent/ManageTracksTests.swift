import Foundation
import Testing
@testable import PalmierPro

@Suite("ToolExecutor — manage_tracks")
@MainActor
struct ManageTracksTests {
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
        let json = try await h.runOK("manage_tracks", args: ["remove": [0]]) as? [String: Any]
        #expect((json?["removedClipIds"] as? [String])?.count == 50)
        #expect((json?["tracks"] as? [[String: Any]])?.count == 2)
        #expect(h.editor.timeline.tracks.count == 2)
        #expect(h.editor.timeline.tracks.allSatisfy { track in !track.clips.contains { $0.mediaType == .text } })
    }

    @Test func removesMultipleTracksWithPreCallIndexes() async throws {
        let h = harness()
        _ = try await h.runOK("manage_tracks", args: ["remove": [0, 2]])
        #expect(h.editor.timeline.tracks.count == 1)
        #expect(h.editor.timelineTrackDisplayLabel(at: 0) == "V1")
    }

    @Test func reordersWithinTypeZoneWithoutClipChurn() async throws {
        let h = harness()
        let movedId = h.editor.timeline.tracks[1].id
        let json = try await h.runOK("manage_tracks", args: ["reorder": [["index": 1, "to": 0]]]) as? [String: Any]
        #expect(h.editor.timeline.tracks[0].id == movedId)
        // A pure reorder moves no clips — the diff must not enumerate the 51 clips.
        #expect(json?["clips"] == nil)
        #expect(json?["shifted"] == nil)
        let order = json?["tracks"] as? [[String: Any]]
        #expect(order?.count == 3)
        #expect(((json?["notes"] as? [String])?.first ?? "").contains("Track indices changed"))
    }

    @Test func setsMuteHiddenAndSyncLock() async throws {
        let h = harness()
        let json = try await h.runOK("manage_tracks", args: [
            "set": [["index": 2, "muted": true], ["index": 0, "hidden": true, "syncLocked": false]],
        ]) as? [String: Any]
        #expect(h.editor.timeline.tracks[2].muted)
        #expect(h.editor.timeline.tracks[0].hidden)
        #expect(!h.editor.timeline.tracks[0].syncLocked)
        let order = json?["tracks"] as? [[String: Any]]
        #expect(order?.first?["hidden"] as? Bool == true)
        #expect(order?.last?["muted"] as? Bool == true)

        // Setting the same values again is a no-op, not a toggle back.
        _ = try await h.runOK("manage_tracks", args: ["set": [["index": 2, "muted": true]]])
        #expect(h.editor.timeline.tracks[2].muted)
    }

    @Test func rejectsOutOfRangeIndexAndEmptyCall() async throws {
        let h = harness()
        #expect(await h.runRaw("manage_tracks", args: ["remove": [5]]).isError)
        #expect(h.editor.timeline.tracks.count == 3)
        #expect(await h.runRaw("manage_tracks", args: [:]).isError)
    }
}
