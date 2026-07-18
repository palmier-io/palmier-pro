import Foundation
import Testing
@testable import PalmierPro

// add_texts caption-group inheritance (BUG-1): text added onto a uniform caption track joins that group
// by default, so group restyle and resync manage it; plain text tracks and opt-outs stay ungrouped.
@Suite("AddTexts — caption grouping")
@MainActor
struct AddTextsGroupingTests {
    private func textClip(id: String, gid: String?, start: Int, duration: Int, text: String) -> Clip {
        var c = Clip(mediaRef: "", mediaType: .text, sourceClipType: .text, startFrame: start, durationFrames: duration)
        c.id = id
        c.textContent = text
        c.captionGroupId = gid
        c.textStyle = TextStyle()
        return c
    }

    private func harness(clips: [Clip]) -> ToolHarness {
        ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: clips)]))
    }

    private func newClip(_ h: ToolHarness, content: String) -> Clip? {
        h.editor.timeline.tracks.flatMap(\.clips).first { $0.mediaType == .text && $0.textContent == content }
    }

    private func entry(track: Int, start: Int, end: Int, content: String, group: String? = nil) -> [String: Any] {
        var e: [String: Any] = ["trackIndex": track, "startFrame": start, "endFrame": end, "content": content]
        if let group { e["captionGroupId"] = group }
        return e
    }

    @Test func joinsUniformCaptionGroupByDefault() async throws {
        let h = harness(clips: [
            textClip(id: "c0", gid: "g1", start: 0, duration: 30, text: "one"),
            textClip(id: "c1", gid: "g1", start: 30, duration: 30, text: "two"),
        ])
        _ = try await h.runOK("add_texts", args: ["entries": [entry(track: 0, start: 120, end: 150, content: "joined")]])
        #expect(newClip(h, content: "joined")?.captionGroupId == "g1")
    }

    @Test func plainTextTrackStaysUngrouped() async throws {
        let h = harness(clips: [
            textClip(id: "t0", gid: nil, start: 0, duration: 30, text: "title"),
        ])
        _ = try await h.runOK("add_texts", args: ["entries": [entry(track: 0, start: 120, end: 150, content: "plain")]])
        #expect(newClip(h, content: "plain")?.captionGroupId == nil)
    }

    @Test func mixedGroupsBlockInheritance() async throws {
        let h = harness(clips: [
            textClip(id: "c0", gid: "g1", start: 0, duration: 30, text: "one"),
            textClip(id: "c1", gid: "g2", start: 30, duration: 30, text: "two"),
        ])
        _ = try await h.runOK("add_texts", args: ["entries": [entry(track: 0, start: 120, end: 150, content: "mixed")]])
        #expect(newClip(h, content: "mixed")?.captionGroupId == nil)
    }

    @Test func newTrackStaysUngrouped() async throws {
        let h = harness(clips: [
            textClip(id: "c0", gid: "g1", start: 0, duration: 30, text: "one"),
        ])
        // Omitting trackIndex creates a fresh empty top track — nothing to inherit from.
        _ = try await h.runOK("add_texts", args: ["entries": [["startFrame": 0, "endFrame": 30, "content": "fresh"]]])
        #expect(newClip(h, content: "fresh")?.captionGroupId == nil)
    }

    @Test func explicitGroupWinsOverInheritance() async throws {
        let h = harness(clips: [
            textClip(id: "c0", gid: "g1", start: 0, duration: 30, text: "one"),
            textClip(id: "c1", gid: "g1", start: 30, duration: 30, text: "two"),
            textClip(id: "d0", gid: "g2", start: 300, duration: 30, text: "other"),
        ])
        // g2 clip lives on the same track, so the default is mixed (nil); explicit g2 forces the join.
        _ = try await h.runOK("add_texts", args: ["entries": [entry(track: 0, start: 120, end: 150, content: "forced", group: "g2")]])
        #expect(newClip(h, content: "forced")?.captionGroupId == "g2")
    }

    @Test func noneOptsOutOfInheritance() async throws {
        let h = harness(clips: [
            textClip(id: "c0", gid: "g1", start: 0, duration: 30, text: "one"),
            textClip(id: "c1", gid: "g1", start: 30, duration: 30, text: "two"),
        ])
        _ = try await h.runOK("add_texts", args: ["entries": [entry(track: 0, start: 120, end: 150, content: "solo", group: "none")]])
        #expect(newClip(h, content: "solo")?.captionGroupId == nil)
    }

    @Test func unknownGroupIsRejected() async {
        let h = harness(clips: [
            textClip(id: "c0", gid: "g1", start: 0, duration: 30, text: "one"),
        ])
        let result = await h.runRaw("add_texts", args: ["entries": [entry(track: 0, start: 120, end: 150, content: "bad", group: "ghost")]])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("ghost"))
    }
}
