import Testing
@testable import PalmierPro

@Suite("ToolExecutor — manage_clip_links")
@MainActor
struct ManageClipLinksTests {
    private func harness(linked: Bool = false) -> ToolHarness {
        var video = Fixtures.clip(id: "video", start: 10, duration: 40)
        var audio = Fixtures.clip(id: "audio", mediaType: .audio, start: 5, duration: 50)
        if linked {
            video.linkGroupId = "group"
            audio.linkGroupId = "group"
        }
        return ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ]))
    }

    @Test func linksAndUnlinksWithoutChangingTiming() async throws {
        let h = harness()

        _ = try await h.runOK("manage_clip_links", args: [
            "action": "link",
            "clipIds": ["video", "audio"],
        ])
        let group = try #require(h.editor.clipFor(id: "video")?.linkGroupId)
        #expect(h.editor.clipFor(id: "audio")?.linkGroupId == group)
        #expect(h.editor.clipFor(id: "video")?.startFrame == 10)
        #expect(h.editor.clipFor(id: "audio")?.startFrame == 5)

        _ = try await h.runOK("manage_clip_links", args: [
            "action": "unlink",
            "clipIds": ["video"],
        ])
        #expect(h.editor.clipFor(id: "video")?.linkGroupId == nil)
        #expect(h.editor.clipFor(id: "audio")?.linkGroupId == nil)
        #expect(h.editor.clipFor(id: "video")?.durationFrames == 40)
        #expect(h.editor.clipFor(id: "audio")?.durationFrames == 50)
    }

    @Test func linkingMergesCompleteExistingGroups() async throws {
        var video1 = Fixtures.clip(id: "video1", start: 0, duration: 40)
        var audio1 = Fixtures.clip(id: "audio1", mediaType: .audio, start: 0, duration: 40)
        var video2 = Fixtures.clip(id: "video2", start: 50, duration: 40)
        var audio2 = Fixtures.clip(id: "audio2", mediaType: .audio, start: 50, duration: 40)
        video1.linkGroupId = "group1"
        audio1.linkGroupId = "group1"
        video2.linkGroupId = "group2"
        audio2.linkGroupId = "group2"
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video1, video2]),
            Fixtures.audioTrack(clips: [audio1, audio2]),
        ]))

        _ = try await h.runOK("manage_clip_links", args: [
            "action": "link",
            "clipIds": ["video1", "video2"],
        ])

        let group = try #require(h.editor.clipFor(id: "video1")?.linkGroupId)
        #expect(h.editor.clipFor(id: "audio1")?.linkGroupId == group)
        #expect(h.editor.clipFor(id: "video2")?.linkGroupId == group)
        #expect(h.editor.clipFor(id: "audio2")?.linkGroupId == group)
    }

    @Test func rejectsInvalidAndNoOpRequests() async {
        let h = harness()

        #expect(await h.runRaw("manage_clip_links", args: [
            "action": "link",
            "clipIds": ["video"],
        ]).isError)
        #expect(await h.runRaw("manage_clip_links", args: [
            "action": "unlink",
            "clipIds": ["video"],
        ]).isError)
        #expect(await h.runRaw("manage_clip_links", args: [
            "action": "invalid",
            "clipIds": ["video", "audio"],
        ]).isError)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).allSatisfy { $0.linkGroupId == nil })
    }
}
