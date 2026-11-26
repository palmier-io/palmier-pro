import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("MCP caption punctuation")
@MainActor
struct CaptionPunctuationMCPTests {
    private let firstID = "A1111111-0000-0000-0000-000000000000"
    private let secondID = "B2222222-0000-0000-0000-000000000000"
    private let authoredID = "C3333333-0000-0000-0000-000000000000"

    @Test func groupCleanupPreservesWordFramesAndHasOneUndo() async throws {
        let harness = makeHarness()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let before = harness.editor.timeline
        var expected = before
        expected.tracks[0].clips[0].textContent = "Junior, 5,000, then"
        expected.tracks[0].clips[0].wordTimings?[2].text = "then"
        expected.tracks[0].clips[1].textContent = "Continue, even here"
        expected.tracks[0].clips[1].wordTimings?[2].text = "here"
        let request: [String: Value] = [
            "captionGroupId": .string("captions"),
            "normalizeCaptionPunctuation": .bool(true),
        ]

        try await withClient(harness) { client in
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "update_text" })
            let property = try #require(tool.inputSchema.objectValue?["properties"]?
                .objectValue?["normalizeCaptionPunctuation"]?.objectValue)
            #expect(property["type"] == .string("boolean"))

            let result = try await client.callTool(name: "update_text", arguments: request)
            try #require(result.isError != true)
            #expect(try object(result)["changed"] as? Bool == true)
            #expect(try await texts(client) == [
                String(firstID.prefix(8)): "Junior, 5,000, then",
                String(secondID.prefix(8)): "Continue, even here",
                String(authoredID.prefix(8)): "Overlay, 5,000,",
            ])
            #expect(harness.editor.timeline == expected)

            let repeated = try await client.callTool(name: "update_text", arguments: request)
            #expect(repeated.isError != true)
            #expect(try object(repeated)["changed"] as? Bool == false)
            #expect(harness.editor.timeline == expected)
            _ = try await client.callTool(name: "undo")
            #expect(harness.editor.timeline == before)
            #expect(!undo.canUndo)
            undo.redo()
            #expect(harness.editor.timeline == expected)
        }
    }

    @Test func nonBooleanFlagsAndMixedTargetsAreRefusedAtomically() async throws {
        let harness = makeHarness()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let before = harness.editor.timeline
        let invalidFlags: [Value] = [.int(1), .int(0), .string("true"), .null]

        try await withClient(harness) { client in
            for flag in invalidFlags {
                let result = try await client.callTool(name: "update_text", arguments: [
                    "captionGroupId": .string("captions"),
                    "normalizeCaptionPunctuation": flag,
                ])
                #expect(result.isError == true)
                #expect(harness.editor.timeline == before)
                #expect(!undo.canUndo)
            }
            for otherID in [authoredID, "missing"] {
                let result = try await client.callTool(name: "update_text", arguments: [
                    "clipIds": .array([.string(firstID), .string(otherID)]),
                    "normalizeCaptionPunctuation": .bool(true),
                ])
                #expect(result.isError == true)
                #expect(harness.editor.timeline == before)
                #expect(!undo.canUndo)
            }
        }
    }

    @Test func cleanupCannotBeCombinedWithReplacementOrStyling() async throws {
        let harness = makeHarness()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let before = harness.editor.timeline
        let incompatible: [[String: Value]] = [
            ["content": .string("Different content")],
            ["style": .object(["fontSize": .double(60)])],
            ["entries": .array([.object([
                "clipId": .string(firstID), "content": .string("Different content"),
            ])])],
        ]

        try await withClient(harness) { client in
            for extra in incompatible {
                var request = extra
                request["clipIds"] = .array([.string(firstID)])
                request["normalizeCaptionPunctuation"] = .bool(true)
                let result = try await client.callTool(name: "update_text", arguments: request)
                #expect(result.isError == true)
                #expect(harness.editor.timeline == before)
                #expect(!undo.canUndo)
            }
        }
    }

    @Test func malformedSelectorsCannotFallBackToTheOtherValidSelector() async throws {
        let harness = makeHarness()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let before = harness.editor.timeline
        let invalidClipIDs: [Value] = [
            .string(firstID), .int(1), .bool(true), .null, .object([:]),
            .array([.string(firstID), .string("")]),
            .array([.string(firstID), .int(1)]),
            .array([.string(firstID), .null]),
        ]
        let invalidGroupIDs: [Value] = [
            .string(""), .int(1), .bool(true), .null, .object([:]),
            .array([.string("captions")]),
        ]

        try await withClient(harness) { client in
            for clipIDs in invalidClipIDs {
                let result = try await client.callTool(name: "update_text", arguments: [
                    "clipIds": clipIDs,
                    "captionGroupId": .string("captions"),
                    "normalizeCaptionPunctuation": .bool(true),
                ])
                #expect(result.isError == true)
                #expect(harness.editor.timeline == before)
                #expect(!undo.canUndo)
            }
            for groupID in invalidGroupIDs {
                let result = try await client.callTool(name: "update_text", arguments: [
                    "clipIds": .array([.string(firstID)]),
                    "captionGroupId": groupID,
                    "normalizeCaptionPunctuation": .bool(true),
                ])
                #expect(result.isError == true)
                #expect(harness.editor.timeline == before)
                #expect(!undo.canUndo)
            }
        }
    }

    @Test func commaOnlyCaptionBecomesEmptyWithoutDeletingOrRetimingIt() async throws {
        var caption = Fixtures.clip(id: firstID, mediaType: .text, start: 41, duration: 19)
        caption.captionGroupId = "comma-only"
        caption.textContent = ",,,"
        caption.textStyle = TextStyle()
        caption.textAnimation = TextAnimation(preset: .highlightBlock)
        caption.wordTimings = [.init(text: ",,,", startFrame: 2, endFrame: 17)]
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [caption]),
        ]))
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let before = harness.editor.timeline
        var expected = before
        expected.tracks[0].clips[0].textContent = ""
        expected.tracks[0].clips[0].wordTimings?[0].text = ""
        let request: [String: Value] = [
            "clipIds": .array([.string(firstID)]),
            "normalizeCaptionPunctuation": .bool(true),
        ]

        try await withClient(harness) { client in
            let result = try await client.callTool(name: "update_text", arguments: request)
            try #require(result.isError != true)
            #expect(try object(result)["changed"] as? Bool == true)
            #expect(try object(result)["normalizedCaptionCount"] as? Int == 1)
            #expect(try await texts(client) == [String(firstID.prefix(8)): ""])
            #expect(harness.editor.timeline == expected)

            let repeated = try await client.callTool(name: "update_text", arguments: request)
            #expect(repeated.isError != true)
            #expect(try object(repeated)["changed"] as? Bool == false)
            #expect(harness.editor.timeline == expected)
            _ = try await client.callTool(name: "undo")
            #expect(harness.editor.timeline == before)
            #expect(!undo.canUndo)
        }
    }

    @Test func laterCaptionEditsNormalizeCommasButAuthoredTextStaysVerbatim() async throws {
        let harness = makeHarness()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let before = harness.editor.timeline
        try await withClient(harness) { client in
            let result = try await client.callTool(name: "update_text", arguments: [
                "entries": .array([
                    .object(["clipId": .string(firstID), "content": .string("Revised, 5,000,")]),
                    .object(["clipId": .string(authoredID), "content": .string("Revised overlay, 5,000,")]),
                ]),
            ])
            try #require(result.isError != true)
            let actual = try await texts(client)
            #expect(actual[String(firstID.prefix(8))] == "Revised, 5,000")
            #expect(actual[String(authoredID.prefix(8))] == "Revised overlay, 5,000,")
            #expect(harness.editor.timeline.tracks[0].clips[1] == before.tracks[0].clips[1])
            _ = try await client.callTool(name: "undo")
            #expect(harness.editor.timeline == before)
        }
    }

    @Test func appliedTranslationCaptionsUseTheSamePunctuationRule() async throws {
        let harness = makeHarness()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let before = harness.editor.timeline
        try await withClient(harness) { client in
            let translation = try await client.callTool(name: "translate_captions", arguments: [
                "action": .string("translate"),
                "targetLanguage": .string("es"),
                "beats": .array([.object([
                    "beatId": .string("intro"), "text": .string("Hello, world,"),
                    "startFrame": .int(41), "endFrame": .int(89),
                ])]),
                "customTranslations": .object(["intro": .string("Hola, mundo,")]),
            ])
            try #require(translation.isError != true)
            let jobID = try #require(try object(translation)["id"] as? String)
            let approval = try await client.callTool(name: "translate_captions", arguments: [
                "action": .string("approve_all"), "jobId": .string(jobID),
            ])
            try #require(approval.isError != true)
            let applied = try await client.callTool(name: "translate_captions", arguments: [
                "action": .string("apply"), "jobId": .string(jobID),
            ])
            try #require(applied.isError != true)
            let receipt = try object(applied)
            let ids = try #require(receipt["captionClipIds"] as? [String])
            let id = try #require(ids.first)
            #expect(try await texts(client)[String(id.prefix(8))] == "Hola, mundo")
            let clip = try #require(harness.editor.timeline.tracks.flatMap(\.clips).first { $0.id.hasPrefix(id) })
            #expect(clip.startFrame == 41)
            #expect(clip.endFrame == 89)
            #expect(clip.captionGroupId != nil)
            _ = try await client.callTool(name: "undo")
            #expect(harness.editor.timeline == before)
            #expect(!undo.canUndo)
        }
    }

    private func makeHarness() -> ToolHarness {
        var first = Fixtures.clip(id: firstID, mediaType: .text, start: 0, duration: 90)
        first.captionGroupId = "captions"
        first.textContent = "Junior, 5,000, then,"
        first.textStyle = TextStyle()
        first.textAnimation = TextAnimation(preset: .highlightBlock)
        first.wordTimings = [
            .init(text: "Junior,", startFrame: 0, endFrame: 12),
            .init(text: "5,000,", startFrame: 12, endFrame: 50),
            .init(text: "then,", startFrame: 50, endFrame: 90),
        ]
        var second = first
        second.id = secondID
        second.startFrame = 90
        second.textContent = "Continue, even here,"
        second.wordTimings = [
            .init(text: "Continue,", startFrame: 0, endFrame: 17),
            .init(text: "even", startFrame: 17, endFrame: 38),
            .init(text: "here,", startFrame: 38, endFrame: 90),
        ]
        var authored = Fixtures.clip(id: authoredID, mediaType: .text, start: 180, duration: 90)
        authored.textContent = "Overlay, 5,000,"
        authored.textStyle = TextStyle()
        return ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [first, second, authored]),
        ]))
    }

    private func texts(_ client: Client) async throws -> [String: String] {
        let result = try await client.callTool(name: "get_timeline", arguments: ["captionDetail": .bool(true)])
        let timeline = try object(result)
        let tracks = try #require(timeline["tracks"] as? [[String: Any]])
        var output: [String: String] = [:]
        for track in tracks {
            for group in track["captionGroups"] as? [[String: Any]] ?? [] {
                for row in group["clips"] as? [[Any]] ?? [] {
                    if row.count == 4, let id = row[0] as? String, let content = row[3] as? String {
                        output[id] = content
                    }
                }
            }
            for clip in track["clips"] as? [[String: Any]] ?? [] {
                if let id = clip["id"] as? String, let content = clip["textContent"] as? String {
                    output[id] = content
                }
            }
        }
        return output
    }

    private func object(_ result: (content: [Tool.Content], isError: Bool?)) throws -> [String: Any] {
        let content = try #require(result.content.first)
        guard case .text(let text, _, _) = content else { throw CocoaError(.coderReadCorrupt) }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func withClient(_ harness: ToolHarness, _ operation: (Client) async throws -> Void) async throws {
        let server = Server(name: "caption-punctuation", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "caption-punctuation-tests", version: "1")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            try await operation(client)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }
}
