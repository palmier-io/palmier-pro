import Foundation
import MCP
import Testing

@testable import PalmierPro

@MainActor
private func harness() -> ToolHarness {
    ToolHarness(timeline: Fixtures.timeline(tracks: [
        Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "c1", start: 0, duration: 100, trimStart: 30, trimEnd: 50),
            Fixtures.clip(id: "c2", start: 100, duration: 50),
        ]),
    ]))
}

@MainActor
private func spans(_ h: ToolHarness) -> [[Int]] {
    h.editor.timeline.tracks[0].clips
        .sorted { $0.startFrame < $1.startFrame }
        .map { [$0.startFrame, $0.endFrame] }
}

private func trim(_ clipId: String, _ edge: String, _ length: [String: Any] = [:]) -> [String: Any] {
    var entry: [String: Any] = ["clipId": clipId, "edge": edge]
    entry.merge(length) { current, _ in current }
    return entry
}

private func args(ripple: Bool, _ trims: [[String: Any]]) -> [String: Any] {
    ["ripple": ripple, "trims": trims]
}

@Suite("ToolExecutor — trim_clip")
@MainActor
struct TrimClipToolTests {

    @Test func tailDeltaExtendsAndPushesDownstream() async throws {
        let h = harness()
        let json = try #require(await h.runOK(
            "trim_clip", args: args(ripple: true, [trim("c1", "tail", ["deltaFrames": 20])])
        ) as? [String: Any])
        #expect(json["changed"] as? Bool == true)
        let receipt = try #require((json["trims"] as? [[String: Any]])?.first)
        #expect(receipt["requestedDeltaFrames"] as? Int == 20)
        #expect(receipt["appliedDeltaFrames"] as? Int == 20)
        #expect(receipt["changed"] as? Bool == true)
        #expect(spans(h) == [[0, 120], [120, 170]])
    }

    @Test func tailToFrameLandsTheOutPointOnThatFrame() async throws {
        let h = harness()
        _ = try await h.runOK("trim_clip", args: args(ripple: true, [trim("c1", "tail", ["toFrame": 130])]))
        #expect(spans(h) == [[0, 130], [130, 180]])
        #expect(h.editor.clipFor(id: "c1")?.trimEndFrame == 20)
    }

    @Test func tailShrinkClosesTheGapBehindIt() async throws {
        let h = harness()
        _ = try await h.runOK("trim_clip", args: args(ripple: true, [trim("c1", "tail", ["deltaFrames": -30])]))
        #expect(spans(h) == [[0, 70], [70, 120]])
    }

    @Test func headToFrameKeepsStartAnchoredAndSlidesDownstream() async throws {
        let h = harness()
        _ = try await h.runOK("trim_clip", args: args(ripple: true, [trim("c1", "head", ["toFrame": 20])]))
        #expect(spans(h) == [[0, 80], [80, 130]])
        #expect(h.editor.clipFor(id: "c1")?.trimStartFrame == 50)
    }

    @Test func headDeltaExtendsIntoEarlierSource() async throws {
        let h = harness()
        _ = try await h.runOK("trim_clip", args: args(ripple: true, [trim("c1", "head", ["deltaFrames": 30])]))
        #expect(spans(h) == [[0, 130], [130, 180]])
        #expect(h.editor.clipFor(id: "c1")?.trimStartFrame == 0)
    }

    @Test func edgeAlreadyAtThatFrameIsAReportedNoOp() async throws {
        let h = harness()
        let undoManager = UndoManager()
        h.editor.undo.attach(undoManager)
        let json = try #require(await h.runOK(
            "trim_clip", args: args(ripple: true, [trim("c1", "tail", ["toFrame": 100])])
        ) as? [String: Any])
        #expect(json["changed"] as? Bool == false)
        let receipt = try #require((json["trims"] as? [[String: Any]])?.first)
        #expect(receipt["appliedDeltaFrames"] as? Int == 0)
        #expect(receipt["changed"] as? Bool == false)
        #expect(spans(h) == [[0, 100], [100, 150]])
        #expect(undoManager.canUndo == false)
    }

    @Test func insufficientSourceRefusesAtomicallyWithMaximum() async {
        let h = harness()
        let result = await h.runRaw("trim_clip", args: args(ripple: true, [trim("c1", "tail", ["deltaFrames": 500])]))
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("maxExtendFrames is 50"))
        #expect(spans(h) == [[0, 100], [100, 150]])
    }

    @Test func extendWithNoHandlesFailsAndLeavesTheTimelineAlone() async {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 100)]),
        ]))
        let result = await h.runRaw("trim_clip", args: args(ripple: true, [trim("c1", "tail", ["deltaFrames": 10])]))
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("maxExtendFrames is 0"))
        #expect(h.editor.clipFor(id: "c1")?.durationFrames == 100)
    }

    @Test func blockedShrinkFailsWithTheSyncLockedObstacle() async {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 100)]),
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "b0", start: 60, duration: 40),
                Fixtures.clip(id: "b1", start: 100, duration: 50),
            ]),
        ]))
        let result = await h.runRaw("trim_clip", args: args(ripple: true, [trim("c1", "tail", ["deltaFrames": -20])]))
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("frame 100"))
        #expect(h.editor.clipFor(id: "c1")?.durationFrames == 100)
    }

    @Test func linkedAudioTrimsWithTheVideo() async throws {
        var video = Fixtures.clip(id: "v1", start: 0, duration: 100, trimEnd: 50)
        var audio = Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 100, trimEnd: 50)
        video.linkGroupId = "g"
        audio.linkGroupId = "g"
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ]))
        _ = try await h.runOK("trim_clip", args: args(ripple: true, [trim("v1", "tail", ["deltaFrames": 20])]))
        #expect(h.editor.clipFor(id: "v1")?.endFrame == 120)
        #expect(h.editor.clipFor(id: "a1")?.endFrame == 120)
    }

    @Test func regularTailExtensionOverwritesTheNextClip() async throws {
        let h = harness()
        let json = try #require(await h.runOK(
            "trim_clip", args: args(ripple: false, [trim("c1", "tail", ["deltaFrames": 20])])
        ) as? [String: Any])
        #expect(json["ripple"] as? Bool == false)
        #expect(spans(h) == [[0, 120], [120, 150]])
    }

    @Test func regularHeadExtensionOverwritesThePreviousClip() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "previous", start: 0, duration: 50),
                Fixtures.clip(id: "c1", start: 50, duration: 50, trimStart: 30, trimEnd: 20),
            ]),
        ]))
        _ = try await h.runOK("trim_clip", args: args(ripple: false, [trim("c1", "head", ["deltaFrames": 20])]))
        #expect(spans(h) == [[0, 30], [30, 100]])
        #expect(h.editor.clipFor(id: "c1")?.trimStartFrame == 10)
    }

    @Test func regularShortenLeavesAGap() async throws {
        let h = harness()
        _ = try await h.runOK("trim_clip", args: args(ripple: false, [trim("c1", "tail", ["deltaFrames": -20])]))
        #expect(spans(h) == [[0, 80], [100, 150]])
    }

    @Test func extendToAdjacentFillsTailAndHeadGaps() async throws {
        let tail = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "c1", start: 0, duration: 100, trimEnd: 50),
                Fixtures.clip(id: "c2", start: 125, duration: 50),
            ]),
        ]))
        _ = try await tail.runOK("trim_clip", args: args(ripple: false, [trim("c1", "tail", ["extendToAdjacentClip": true])]))
        #expect(spans(tail) == [[0, 125], [125, 175]])

        let head = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "c0", start: 0, duration: 40),
                Fixtures.clip(id: "c1", start: 60, duration: 40, trimStart: 30),
            ]),
        ]))
        _ = try await head.runOK("trim_clip", args: args(ripple: false, [trim("c1", "head", ["extendToAdjacentClip": true])]))
        #expect(spans(head) == [[0, 40], [40, 100]])
    }

    @Test func adjacentModeReportsNoOpAndMissingNeighbor() async throws {
        let touching = harness()
        let json = try #require(await touching.runOK(
            "trim_clip", args: args(ripple: false, [trim("c1", "tail", ["extendToAdjacentClip": true])])
        ) as? [String: Any])
        #expect(json["changed"] as? Bool == false)

        let alone = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "c1", start: 0, duration: 100, trimEnd: 50),
            ]),
        ]))
        let result = await alone.runRaw("trim_clip", args: args(ripple: false, [trim("c1", "tail", ["extendToAdjacentClip": true])]))
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("no adjacent clip"))
    }

    @Test func linkedSourceLimitRefusesTheWholeRegularTrim() async {
        var video = Fixtures.clip(id: "v1", start: 0, duration: 100, trimEnd: 50)
        var audio = Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 100, trimEnd: 5)
        video.linkGroupId = "g"
        audio.linkGroupId = "g"
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ]))
        let undoManager = UndoManager()
        h.editor.undo.attach(undoManager)
        let result = await h.runRaw("trim_clip", args: args(ripple: false, [trim("v1", "tail", ["deltaFrames": 10])]))
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("maxExtendFrames is 5"))
        #expect(h.editor.clipFor(id: "v1")?.durationFrames == 100)
        #expect(h.editor.clipFor(id: "a1")?.durationFrames == 100)
        #expect(undoManager.canUndo == false)
    }

    @Test func unrepresentableRetimedEdgeRefusesWithoutOvershooting() async {
        for ripple in [false, true] {
            let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
                Fixtures.videoTrack(clips: [
                    Fixtures.clip(id: "c1", start: 0, duration: 100, trimEnd: 50, speed: 0.5),
                ]),
            ]))
            let result = await h.runRaw("trim_clip", args: args(ripple: ripple, [trim("c1", "tail", ["toFrame": 101])]))
            #expect(result.isError)
            #expect(ToolHarness.textOf(result).contains("nearestAchievableDeltaFrames is 2"))
            #expect(h.editor.clipFor(id: "c1")?.durationFrames == 100)
        }
    }

    @Test func absoluteFrameHasNoTimelinePositionCeiling() async throws {
        let start = 30_000_000
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "c1", start: start, duration: 100, trimEnd: 50),
                Fixtures.clip(id: "c2", start: start + 100, duration: 50),
            ]),
        ]))
        _ = try await h.runOK("trim_clip", args: args(ripple: true, [trim("c1", "tail", ["toFrame": start + 120])]))
        #expect(h.editor.clipFor(id: "c1")?.endFrame == start + 120)
        #expect(h.editor.clipFor(id: "c2")?.startFrame == start + 120)
    }

    @Test func captionGapFillAndOverwriteRescaleWordTiming() async throws {
        var caption = Fixtures.clip(id: "caption-1", mediaType: .text, start: 0, duration: 100)
        caption.wordTimings = [WordTiming(text: "word", startFrame: 0, endFrame: 100)]
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                caption,
                Fixtures.clip(id: "caption-2", mediaType: .text, start: 130, duration: 50),
            ]),
        ]))
        _ = try await h.runOK("trim_clip", args: args(ripple: false, [trim("caption-1", "tail", ["extendToAdjacentClip": true])]))
        #expect(spans(h) == [[0, 130], [130, 180]])

        _ = try await h.runOK("trim_clip", args: args(ripple: false, [trim("caption-1", "tail", ["deltaFrames": 20])]))
        #expect(spans(h) == [[0, 150], [150, 180]])
        #expect(h.editor.clipFor(id: "caption-1")?.wordTimings?.first?.endFrame == 150)
    }

    @Test func bulkCaptionRetimeAppliesAllTrimsInOneUndoStep() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "cap-1", mediaType: .text, start: 0, duration: 60),
                Fixtures.clip(id: "cap-2", mediaType: .text, start: 70, duration: 60),
                Fixtures.clip(id: "cap-3", mediaType: .text, start: 140, duration: 60),
            ]),
        ]))
        let undoManager = UndoManager()
        h.editor.undo.attach(undoManager)

        let json = try #require(await h.runOK("trim_clip", args: args(ripple: false, [
            trim("cap-1", "tail", ["extendToAdjacentClip": true]),
            trim("cap-2", "head", ["deltaFrames": -5]),
            trim("cap-2", "tail", ["deltaFrames": 5]),
            trim("cap-3", "tail", ["toFrame": 190]),
        ])) as? [String: Any])
        #expect(json["changed"] as? Bool == true)
        #expect((json["trims"] as? [[String: Any]])?.count == 4)
        #expect(spans(h) == [[0, 70], [75, 135], [140, 190]])

        undoManager.undo()
        #expect(spans(h) == [[0, 60], [70, 130], [140, 200]])
        #expect(undoManager.canUndo == false)
    }

    @Test func bulkFailsAtomicallyWhenOneEntryCannotLand() async {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "c1", start: 0, duration: 100, trimEnd: 50),
                Fixtures.clip(id: "c2", start: 120, duration: 50),
            ]),
        ]))
        let undoManager = UndoManager()
        h.editor.undo.attach(undoManager)
        let result = await h.runRaw("trim_clip", args: args(ripple: false, [
            trim("c1", "tail", ["deltaFrames": 10]),
            trim("c2", "tail", ["deltaFrames": 10]),
        ]))
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("trims[1]"))
        #expect(spans(h) == [[0, 100], [120, 170]])
        #expect(undoManager.canUndo == false)
    }

    @Test func sameClipHeadAndTailComposeInOneCall() async throws {
        let h = harness()
        _ = try await h.runOK("trim_clip", args: args(ripple: false, [
            trim("c1", "head", ["deltaFrames": -10]),
            trim("c1", "tail", ["deltaFrames": -10]),
        ]))
        let c1 = try #require(h.editor.clipFor(id: "c1"))
        #expect(c1.startFrame == 10)
        #expect(c1.endFrame == 90)
        #expect(c1.trimStartFrame == 40)
        #expect(c1.trimEndFrame == 60)
    }

    @Test func combinedShrinksBelowOneFrameAreRefused() async {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 10, trimStart: 20, trimEnd: 20)]),
        ]))
        let result = await h.runRaw("trim_clip", args: args(ripple: false, [
            trim("c1", "head", ["deltaFrames": -6]),
            trim("c1", "tail", ["deltaFrames": -6]),
        ]))
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("below one frame"))
        #expect(h.editor.clipFor(id: "c1")?.durationFrames == 10)
    }

    @Test func duplicateEdgeIsRefusedIncludingViaLinkedPartner() async {
        let h = harness()
        let duplicate = await h.runRaw("trim_clip", args: args(ripple: false, [
            trim("c1", "tail", ["deltaFrames": -5]),
            trim("c1", "tail", ["deltaFrames": -5]),
        ]))
        #expect(duplicate.isError)
        #expect(ToolHarness.textOf(duplicate).contains("already trimmed"))

        var video = Fixtures.clip(id: "v1", start: 0, duration: 100, trimEnd: 50)
        var audio = Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 100, trimEnd: 50)
        video.linkGroupId = "g"
        audio.linkGroupId = "g"
        let linked = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ]))
        let viaPartner = await linked.runRaw("trim_clip", args: args(ripple: false, [
            trim("v1", "tail", ["deltaFrames": 5]),
            trim("a1", "tail", ["deltaFrames": 5]),
        ]))
        #expect(viaPartner.isError)
        #expect(ToolHarness.textOf(viaPartner).contains("linked"))
        #expect(linked.editor.clipFor(id: "v1")?.durationFrames == 100)
    }

    @Test func rippleBatchIsRefused() async {
        let h = harness()
        let result = await h.runRaw("trim_clip", args: args(ripple: true, [
            trim("c1", "tail", ["deltaFrames": 5]),
            trim("c2", "tail", ["deltaFrames": 5]),
        ]))
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("one trim per call"))
        #expect(spans(h) == [[0, 100], [100, 150]])
    }

    @Test func regularTrimUndoesAsOneStep() async throws {
        let h = harness()
        let undoManager = UndoManager()
        h.editor.undo.attach(undoManager)
        _ = try await h.runOK("trim_clip", args: args(ripple: false, [trim("c1", "tail", ["deltaFrames": 20])]))
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(spans(h) == [[0, 100], [100, 150]])
        #expect(undoManager.canUndo == false)
    }

    @Test func rejectsMalformedRequests() async {
        let cases: [(label: String, args: [String: Any])] = [
            ("no ripple", ["trims": [trim("c1", "tail", ["deltaFrames": 10])]]),
            ("missing trims", ["ripple": true]),
            ("empty trims", args(ripple: true, [])),
            ("no length given", args(ripple: true, [trim("c1", "tail")])),
            ("both lengths given", args(ripple: true, [trim("c1", "tail", ["deltaFrames": 10, "toFrame": 130])])),
            ("adjacent and delta given", args(ripple: false, [trim("c1", "tail", ["deltaFrames": 10, "extendToAdjacentClip": true])])),
            ("false adjacent mode", args(ripple: false, [trim("c1", "tail", ["extendToAdjacentClip": false])])),
            ("ripple adjacent mode", args(ripple: true, [trim("c1", "tail", ["extendToAdjacentClip": true])])),
            ("unknown edge", args(ripple: true, [trim("c1", "middle", ["deltaFrames": 10])])),
            ("zero delta", args(ripple: true, [trim("c1", "tail", ["deltaFrames": 0])])),
            ("head toFrame past the clip", args(ripple: true, [trim("c1", "head", ["toFrame": 200])])),
            ("tail toFrame before the head", args(ripple: true, [trim("c1", "tail", ["toFrame": 0])])),
            ("overflowing delta", args(ripple: true, [trim("c1", "tail", ["deltaFrames": Int.min])])),
            ("oversized derived delta", args(ripple: true, [trim("c1", "tail", ["toFrame": Int.max])])),
            ("unknown clip", args(ripple: true, [trim("nope", "tail", ["deltaFrames": 10])])),
            ("unknown entry field", args(ripple: true, [trim("c1", "tail", ["deltaFrames": 10, "sideways": true])])),
            ("unknown top-level field", ["ripple": true, "trims": [trim("c1", "tail", ["deltaFrames": 10])], "clipId": "c1"]),
        ]
        for (label, malformed) in cases {
            let h = harness()
            let result = await h.runRaw("trim_clip", args: malformed)
            #expect(result.isError, "expected \(label) to be rejected")
            #expect(spans(h) == [[0, 100], [100, 150]], "\(label) must not mutate the timeline")
        }
    }
}

@Suite("MCP trim_clip")
@MainActor
struct MCPTrimClipTests {

    @Test func discoveryMutationReadbackAndUndo() async throws {
        let h = harness()
        let undoManager = UndoManager()
        h.editor.undo.attach(undoManager)

        let server = Server(
            name: "palmier-pro-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: h.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "trim-clip-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)

            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "trim_clip" })
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            let entrySchema = try #require(properties["trims"]?.objectValue?["items"]?.objectValue)
            let entryProperties = try #require(entrySchema["properties"]?.objectValue)
            let edges = try #require(entryProperties["edge"]?.objectValue?["enum"]?.arrayValue)
            #expect(edges.compactMap(\.stringValue) == ["head", "tail"])
            #expect(entryProperties["deltaFrames"]?.objectValue?["type"]?.stringValue == "integer")
            let required = try #require(tool.inputSchema.objectValue?["required"]?.arrayValue)
            #expect(Set(required.compactMap(\.stringValue)) == ["ripple", "trims"])

            let trim = try await client.callTool(name: "trim_clip", arguments: [
                "ripple": .bool(false),
                "trims": .array([.object([
                    "clipId": .string("c1"),
                    "edge": .string("tail"),
                    "toFrame": .int(120),
                ])]),
            ])
            #expect(trim.isError != true)

            let frames = try await timelineFrames(client: client)
            #expect(frames == [[0, 120], [120, 150]])

            #expect((try await client.callTool(name: "undo")).isError != true)
            let restored = try await timelineFrames(client: client)
            #expect(restored == [[0, 100], [100, 150]])

            let ripple = try await client.callTool(name: "trim_clip", arguments: [
                "ripple": .bool(true),
                "trims": .array([.object([
                    "clipId": .string("c1"),
                    "edge": .string("tail"),
                    "toFrame": .int(130),
                ])]),
            ])
            #expect(ripple.isError != true)
            #expect(try await timelineFrames(client: client) == [[0, 130], [130, 180]])
            #expect((try await client.callTool(name: "undo")).isError != true)

            let invalid = try await client.callTool(name: "trim_clip", arguments: [
                "ripple": .bool(true),
                "trims": .array([.object([
                    "clipId": .string("c1"),
                    "edge": .string("tail"),
                    "extendToAdjacentClip": .bool(true),
                ])]),
            ])
            #expect(invalid.isError == true)

            let noOp = try await client.callTool(name: "trim_clip", arguments: [
                "ripple": .bool(false),
                "trims": .array([.object([
                    "clipId": .string("c1"),
                    "edge": .string("tail"),
                    "toFrame": .int(100),
                ])]),
            ])
            let noOpPayload = try #require(
                JSONSerialization.jsonObject(with: Data(try text(noOp.content).utf8)) as? [String: Any]
            )
            #expect(noOpPayload["changed"] as? Bool == false)
            #expect(try await timelineFrames(client: client) == [[0, 100], [100, 150]])
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func timelineFrames(client: Client) async throws -> [[Int]] {
        let result = try await client.callTool(name: "get_timeline")
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(text(result.content).utf8)) as? [String: Any]
        )
        let tracks = try #require(payload["tracks"] as? [[String: Any]])
        return tracks
            .flatMap { $0["clips"] as? [[String: Any]] ?? [] }
            .compactMap { $0["frames"] as? [Int] }
            .sorted { ($0.first ?? 0) < ($1.first ?? 0) }
    }

    private func text(_ content: [Tool.Content]) throws -> String {
        for item in content {
            if case .text(let text, _, _) = item { return text }
        }
        throw CocoaError(.coderReadCorrupt)
    }
}
