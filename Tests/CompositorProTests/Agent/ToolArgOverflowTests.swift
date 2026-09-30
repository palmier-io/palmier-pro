import Foundation
import Testing
@testable import CompositorPro

// Out-of-range numeric tool args (e.g. {"startFrame": 1e19}) must not trap Int(_:).
@Suite("Tool arg numeric overflow: no traps")
struct ToolArgOverflowTests {

    @Test func safeIntRejectsOverflowAndNonFinite() {
        #expect(safeInt(1e19) == nil)
        #expect(safeInt(-1e19) == nil)
        #expect(safeInt(1e300) == nil)
        #expect(safeInt(.nan) == nil)
        #expect(safeInt(.infinity) == nil)
        #expect(safeInt(-.infinity) == nil)
        #expect(safeInt(3.0) == 3)
        #expect(safeInt(3.9) == 3)        // truncates toward zero
        #expect(safeInt(-3.9) == -3)
        #expect(safeInt(0) == 0)
    }

    @Test func clampIntNeverOverflows() {
        #expect(clampInt(1e300, min: 0, max: 100) == 100)
        #expect(clampInt(-1e300, min: 0, max: 100) == 0)
        #expect(clampInt(.nan, min: 5, max: 100) == 5)
        #expect(clampInt(.infinity, min: 0, max: 100) == 100)
        #expect(clampInt(42.4, min: 0, max: 100) == 42)
    }

    /// Exactly the JSON that crashed the live app via the MCP socket.
    @Test func dictIntDoesNotTrapOnHugeJSONNumber() throws {
        let json = #"{"startFrame": 1e19}"#.data(using: .utf8)!
        let args = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(args.int("startFrame") == nil)        // was: hard crash
        #expect((args.int("startFrame") ?? 0) == 0)
    }

    @Test @MainActor func parseWordSpansHandlesLargeValuesWithoutCrashing() throws {
        // 2e9 is a valid Int and must still parse (the freeze is fixed by bounding the loop at the use site).
        let spans = try ToolExecutor.parseWordSpans([[0, 2_000_000_000]])
        #expect(spans.first?.1 == 2_000_000_000)
        // Out-of-range doubles are coerced without trapping; the property under test is "does not crash".
        let huge = try ToolExecutor.parseWordSpans([1e19])
        #expect(huge.count == 1)
    }
}

@Suite("Tool arg numeric overflow: end to end")
@MainActor
struct ToolArgOverflowE2ETests {

    /// The exact crash repro: get_timeline with an out-of-range startFrame must return cleanly.
    @Test func getTimelineSurvivesHugeStartFrame() async {
        let h = ToolHarness(timeline: Fixtures.timeline(
            tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 100)])]
        ))
        let result = await h.runRaw("get_timeline", args: ["startFrame": 1e19])
        #expect(result.isError == false)             // returns a timeline instead of crashing
        #expect(result.content.isEmpty == false)
    }

    /// ripple_delete_ranges with an absurd finite range must not trap on Double→Int.
    @Test func rippleDeleteSurvivesHugeRange() async {
        let h = ToolHarness(timeline: Fixtures.timeline(
            tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 100)])]
        ))
        let result = await h.runRaw("ripple_delete_ranges", args: [
            "trackIndex": 0,
            "units": "frames",
            "ranges": [[0.0, 1e300]],
        ])
        // We only require that it returned (a result, ok or error) rather than crashing the process.
        #expect(result.content.isEmpty == false)
    }

    /// An out-of-range keyframe frame must be rejected, not silently clamped to Int.max.
    @Test func setKeyframesRejectsOverflowFrame() async {
        let clip = Fixtures.clip(id: "C1", start: 0, duration: 100)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
        let result = await h.runRaw("set_keyframes", args: [
            "clipId": "C1",
            "property": "opacity",
            "keyframes": [[1e19, 0.5]],
        ])
        #expect(result.isError == true)
    }
}

/// #264: a raw JSON integer near Int.max decodes cleanly, so only an explicit frame-domain
/// ceiling at the arg boundary keeps `startFrame + durationFrames` from trapping the process.
@Suite("Tool arg frame ceiling")
@MainActor
struct ToolArgFrameCeilingTests {

    private func harnessWithVideoTrack() -> (ToolHarness, MediaAsset) {
        let h = ToolHarness()
        _ = h.editor.insertTrack(at: 0, type: .video)
        return (h, h.addAsset(type: .video))
    }

    @Test func addClipsRejectsIntMaxStartFrame() async {
        let (h, asset) = harnessWithVideoTrack()
        let result = await h.runRaw("add_clips", args: [
            "entries": [["mediaRef": asset.id, "trackIndex": 0, "startFrame": Int.max]],
        ])
        #expect(result.isError == true)
        #expect(ToolHarness.textOf(result).contains("must be between"))
        #expect(h.editor.timeline.tracks[0].clips.isEmpty)
    }

    @Test func insertClipsRejectsIntMaxAtFrame() async {
        let (h, asset) = harnessWithVideoTrack()
        let result = await h.runRaw("insert_clips", args: [
            "entries": [["mediaRef": asset.id, "trackIndex": 0, "atFrame": Int.max, "durationFrames": 30]],
        ])
        #expect(result.isError == true)
        #expect(ToolHarness.textOf(result).contains("must be between"))
    }

    @Test func moveClipsRejectsIntMaxToFrame() async {
        let clip = Fixtures.clip(id: "C1", start: 0, duration: 100)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
        let result = await h.runRaw("move_clips", args: ["moves": [["clipId": "C1", "toFrame": Int.max]]])
        #expect(result.isError == true)
        #expect(ToolHarness.textOf(result).contains("must be between"))
        #expect(h.editor.timeline.tracks[0].clips[0].startFrame == 0)
    }

    @Test func setClipPropertiesRejectsIntMaxDuration() async {
        let clip = Fixtures.clip(id: "C1", start: 0, duration: 100)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
        let result = await h.runRaw("set_clip_properties", args: [
            "clipIds": ["C1"],
            "durationFrames": Int.max,
        ])
        #expect(result.isError == true)
        #expect(ToolHarness.textOf(result).contains("must be between"))
    }

    @Test func setClipPropertiesRejectsNegativeDuration() async {
        let clip = Fixtures.clip(id: "C1", start: 0, duration: 100)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
        let result = await h.runRaw("set_clip_properties", args: [
            "clipIds": ["C1"],
            "durationFrames": Int.min,
        ])
        #expect(result.isError == true)
    }

    @Test func addTextsRejectsIntMaxStartFrame() async {
        let (h, _) = harnessWithVideoTrack()
        let result = await h.runRaw("add_texts", args: [
            "entries": [["startFrame": Int.max, "endFrame": 60, "content": "Title"]],
        ])
        #expect(result.isError == true)
        #expect(ToolHarness.textOf(result).contains("must be between"))
    }

    /// `durationFrames * speed` converts back to Int, so an unbounded speed traps the same way.
    @Test func setClipPropertiesRejectsOverflowSpeed() async {
        let clip = Fixtures.clip(id: "C1", start: 0, duration: 100)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
        let result = await h.runRaw("set_clip_properties", args: [
            "clipIds": ["C1"],
            "speed": 1e300,
        ])
        #expect(result.isError == true)
        #expect(ToolHarness.textOf(result).contains("speed must be <="))
    }

    /// manage_multicam parses args by hand instead of decoding them, so the ceiling has to
    /// hold at dispatch rather than inside `decodeToolArgs`.
    @Test func handParsedToolRejectsIntMaxStartFrame() async {
        let h = ToolHarness()
        h.addAsset(id: "camA", type: .video, duration: 120)
        h.addAsset(id: "camB", type: .video, duration: 110)
        let result = await h.runRaw("manage_multicam", args: [
            "create": [
                "members": [
                    ["mediaRef": "camA", "kind": "angle"],
                    ["mediaRef": "camB", "kind": "angle"],
                ],
                "startFrame": Int.max,
            ] as [String: Any],
        ])
        #expect(result.isError == true)
        #expect(ToolHarness.textOf(result).contains("must be between"))
    }

    @Test func frameArgAtTheCeilingIsNotRejectedForRange() async {
        let (h, asset) = harnessWithVideoTrack()
        let result = await h.runRaw("add_clips", args: [
            "entries": [["mediaRef": asset.id, "trackIndex": 0, "startFrame": maxFrameArg, "endFrame": 30]],
        ])
        #expect(ToolHarness.textOf(result).contains("must be between") == false)
    }
}
