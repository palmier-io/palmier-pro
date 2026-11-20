import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("add_outro")
@MainActor
struct AddOutroToolTests {
    /// A 10-second picture, so an outro has somewhere to land.
    private func picture(seconds: Double = 10) async throws -> (ToolHarness, Clip) {
        let harness = ToolHarness()
        let url = try await FixtureVideo.write(
            scenes: (0 ..< Int(seconds * 2)).map { index in
                let value = UInt8((index * 37) % 256)
                return FixtureVideo.Scene(
                    rgb: (value, UInt8((255 - Int(value)) % 256), 120), seconds: 0.5
                )
            },
            fps: 30, size: 320, fileType: .mov
        )
        let asset = harness.addAsset(type: .video, duration: seconds, hasAudio: true)
        harness.editor.mediaManifest.entries = [MediaManifestEntry(
            id: asset.id, name: asset.name, type: .video,
            source: .external(absolutePath: url.path), duration: seconds
        )]
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": asset.id, "startFrame": 0, "source": [0.0, seconds]],
        ]])
        let clip = try #require(harness.editor.timeline.tracks.flatMap(\.clips)
            .first { $0.mediaType == .video })
        return (harness, clip)
    }

    private func texts(_ harness: ToolHarness) -> [Clip] {
        harness.editor.timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .text }
    }

    /// Errors surface at the tool boundary as an error result, not a thrown ToolError.
    private func expectFailure(
        _ name: String, _ args: [String: Any], containing needle: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        let result = await ToolHarness().runRaw(name, args: args)
        guard result.isError else { return false }
        if let needle {
            let text = ToolHarness.textOf(result)
            return text.localizedCaseInsensitiveContains(needle)
        }
        return true
    }

    @Test("Credits roll over a playing picture is one undoable step")
    func creditsRollIsOneUndoStep() async throws {
        let (harness, _) = try await picture()
        let before = harness.editor.timeline.totalFrames
        let receipt = try #require(
            try await harness.runOK("add_outro", args: [
                "credits": [
                    ["name": "Directed by", "role": "A. Editor"],
                    ["name": "Music by", "role": "S. Composer"],
                ],
                "durationFrames": 300,
            ]) as? [String: Any]
        )
        #expect(receipt["changed"] as? Bool == true)
        #expect(receipt["undoSteps"] as? Int == 1)
        #expect(receipt["creditLineCount"] as? Int == 2)
        #expect(receipt["durationFrames"] as? Int == 300)
        // The outro fills the tail of the existing picture rather than extending it.
        #expect(harness.editor.timeline.totalFrames == before)

        let roll = try #require(texts(harness).first { $0.textContent?.contains("A. Editor") == true })
        #expect(roll.textContent == "Directed by\nA. Editor\nMusic by\nS. Composer")
        #expect(roll.startFrame == before - 300)
        #expect(roll.durationFrames == 300)
    }

    @Test("The roll travels off-frame and fades, so it is readable mid-passage")
    func rollMotionIsBaked() async throws {
        let (harness, _) = try await picture()
        _ = try await harness.runOK("add_outro", args: [
            "credits": [["name": "A. Editor"]], "durationFrames": 300,
        ])
        let roll = try #require(texts(harness).first)
        let position = try #require(roll.positionTrack?.keyframes).sorted { $0.frame < $1.frame }
        #expect(position.count == 2)
        #expect(position[0].value.b > 1.0, "must begin below the frame")
        #expect(position[1].value.b < 0.0, "must finish above the frame")
        #expect(position[0].value.a == position[1].value.a, "roll stays horizontally centred")
        let opacity = try #require(roll.opacityTrack?.keyframes)
        #expect(opacity.first?.value == 0)
        #expect(opacity.last?.value == 0)
        #expect(opacity.contains { $0.value == 1 })
    }

    @Test("Subscribe card is held separately from the credits when both are asked for")
    func subscribeAndCreditsCoexist() async throws {
        let (harness, _) = try await picture()
        let receipt = try #require(
            try await harness.runOK("add_outro", args: [
                "credits": [["name": "A. Editor"]],
                "subscribe": ["channel": "Compositor Pro", "handle": "@cpro"],
                "durationFrames": 300,
            ]) as? [String: Any]
        )
        #expect(receipt["hasSubscribeCard"] as? Bool == true)
        let clips = texts(harness)
        #expect(clips.count == 2, "one roll and one card, each on its own track")
        let card = try #require(clips.first { $0.textContent?.contains("SUBSCRIBE") == true })
        #expect(card.textContent?.contains("@cpro") == true)
        let roll = try #require(clips.first { $0.textContent == "A. Editor" })
        #expect(card.durationFrames < roll.durationFrames, "the card gives way to the credits")
        #expect(card.startFrame == roll.startFrame)
    }

    @Test("A thanks card is worded for someone who already subscribed")
    func thanksCardWording() async throws {
        let (harness, _) = try await picture()
        _ = try await harness.runOK("add_outro", args: [
            "subscribe": ["channel": "Compositor Pro", "kind": "thanks"], "durationFrames": 300,
        ])
        #expect(texts(harness).first?.textContent?.contains("THANKS FOR SUBSCRIBING") == true)
    }

    @Test("YouTube duration outside 5-20 seconds is refused and changes nothing")
    func youtubeWindowIsEnforced() async throws {
        let (harness, _) = try await picture()
        let before = harness.editor.timeline.tracks
        let result = await harness.runRaw("add_outro", args: [
            "subscribe": ["channel": "C"], "durationFrames": 90, "platform": "youtube",
        ])
        #expect(result.isError, "90 frames is outside YouTube's 5-20 second window")
        #expect(ToolHarness.textOf(result).contains("150"))
        #expect(harness.editor.timeline.tracks == before, "a refusal must not mutate")
    }

    @Test("A duration inside the YouTube window is accepted")
    func youtubeWindowAccepts() async throws {
        let (harness, _) = try await picture()
        let receipt = try #require(
            try await harness.runOK("add_outro", args: [
                "subscribe": ["channel": "C"], "durationFrames": 300, "platform": "youtube",
            ]) as? [String: Any]
        )
        #expect(receipt["platform"] as? String == "youtube")
    }

    @Test("Neither credits nor a card is refused rather than silently doing nothing")
    func refusesNoOp() async throws {
        let (harness, _) = try await picture()
        let before = harness.editor.timeline.tracks
        let result = await harness.runRaw("add_outro", args: ["durationFrames": 300])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("nothing"))
        #expect(harness.editor.timeline.tracks == before)
    }

    @Test("A credits list with no usable text is refused, not drawn blank")
    func refusesBlankCredits() async throws {
        let (harness, _) = try await picture()
        let result = await harness.runRaw("add_outro", args: [
            "credits": [["name": "   "]], "durationFrames": 300,
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("no usable text"))
    }

    @Test("A subscribe card without a channel is refused")
    func refusesChannellessCard() async throws {
        let (harness, _) = try await picture()
        let result = await harness.runRaw("add_outro", args: [
            "subscribe": ["handle": "@cpro"], "durationFrames": 300,
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("channel"))
    }

    @Test("Unknown enum values are refused rather than defaulted")
    func refusesUnknownEnums() async throws {
        let (harness, _) = try await picture()
        let badArgs: [[String: Any]] = [
            ["platform": "tiktok"],
            ["subscribe": ["channel": "C", "kind": "maybe"] as [String: Any]],
        ]
        for bad in badArgs {
            var args: [String: Any] = ["durationFrames": 300]
            for (key, value) in bad { args[key] = value }
            let result = await harness.runRaw("add_outro", args: args)
            #expect(result.isError, "unknown value in \(bad.keys.sorted()) must not be defaulted")
        }
    }

    @Test("An unknown argument is rejected, so a typo cannot silently change nothing")
    func rejectsUnknownKeys() async throws {
        let (harness, _) = try await picture()
        let result = await harness.runRaw("add_outro", args: ["credit": []])
        #expect(result.isError, "a mistyped key must not be silently ignored")
    }

    /// Undo is proven through the MCP boundary, which is where the tool is actually reached.
    @Test("Discovery, schema, one-shot build, and a single undo through MCP")
    func mcpDiscoveryAndUndo() async throws {
        let (harness, _) = try await picture()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)
        let server = Server(
            name: "outro-test", version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "outro-test", version: "1.0.0")
        try await server.start(transport: transports.server)
        try await client.connect(transport: transports.client)

        let (tools, _) = try await client.listTools()
        let tool = try #require(tools.first { $0.name == "add_outro" })
        let schema = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
        #expect(schema.keys.sorted() == ["credits", "durationFrames", "platform", "subscribe"])
        #expect(
            schema["platform"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue)
                == ["generic", "youtube"]
        )

        let before = harness.editor.timeline.tracks
        let add = try await client.callTool(name: "add_outro", arguments: [
            "credits": .array([.object(["name": .string("A. Editor"), "role": .string("Editor")])]),
            "subscribe": .object([
                "channel": .string("Compositor Pro"), "handle": .string("@cpro"),
            ]),
            "durationFrames": .int(300),
        ])
        #expect(add.isError != true)
        #expect(harness.editor.timeline.tracks != before)
        #expect(texts(harness).count == 2)

        let undone = try await client.callTool(name: "undo")
        #expect(undone.isError != true)
        #expect(harness.editor.timeline.tracks == before, "one undo restores the whole tail")
        #expect(texts(harness).isEmpty)
    }
}
