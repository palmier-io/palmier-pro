import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("apply_transition / remove_transition")
@MainActor
struct TransitionToolTests {
    private func twoClipFixture() async throws -> (ToolHarness, Clip, Clip) {
        let harness = ToolHarness()
        let a = harness.addAsset(type: .video, duration: 8, hasAudio: true)
        let b = harness.addAsset(type: .video, duration: 8, hasAudio: true)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": a.id, "startFrame": 0, "source": [0.0, 4.0]],
            ["mediaRef": b.id, "startFrame": 120, "source": [1.0, 5.0]],
        ]])
        let clips = harness.editor.timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .video }
        let outgoing = try #require(clips.first { $0.startFrame == 0 })
        let incoming = try #require(clips.first { $0.startFrame == 120 })
        #expect(incoming.trimStartFrame == 30)
        return (harness, outgoing, incoming)
    }

    @Test func dissolveBuildsOverlayAudioFadesAndRecordAsOneUndo() async throws {
        let (harness, outgoing, incoming) = try await twoClipFixture()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)
        let videoTracksBefore = harness.editor.timeline.tracks.filter { $0.type == .video }.count

        let receipt = try await harness.runOK("apply_transition", args: [
            "outgoingClipId": outgoing.id, "incomingClipId": incoming.id,
            "type": "dissolve", "durationFrames": 6,
        ]) as? [String: Any]
        #expect(receipt?["type"] as? String == "dissolve")

        let editor = harness.editor
        #expect(editor.timeline.tracks.filter { $0.type == .video }.count == videoTracksBefore + 1)
        let overlay = try #require(editor.timeline.tracks.flatMap(\.clips).first {
            $0.mediaType == .video && $0.startFrame == 117
        })
        #expect(overlay.durationFrames == 6)
        #expect(overlay.trimStartFrame == 27)
        let opacity = try #require(overlay.opacityTrack?.keyframes)
        #expect(opacity.map(\.frame) == [0, 6])
        #expect(opacity.map(\.value) == [0, 1])

        let outgoingAudio = try #require(editor.timeline.tracks.flatMap(\.clips).first {
            $0.mediaType == .audio && $0.linkGroupId == outgoing.linkGroupId
        })
        #expect(outgoingAudio.fadeOutFrames == 3)
        let overlayAudios = editor.timeline.tracks.flatMap(\.clips).filter {
            $0.mediaType == .audio && $0.startFrame == 117
        }
        #expect(overlayAudios.map(\.fadeInFrames) == [3])
        #expect(editor.timeline.transitions.count == 1)

        undoManager.undo()
        #expect(editor.timeline.transitions.isEmpty)
        #expect(editor.timeline.tracks.filter { $0.type == .video }.count == videoTracksBefore)
        #expect(editor.timeline.tracks.flatMap(\.clips).first {
            $0.mediaType == .audio && $0.linkGroupId == outgoing.linkGroupId
        }?.fadeOutFrames == 0)
    }

    @Test func dipToBlackUsesKeyframesAndRemovesCleanly() async throws {
        let (harness, outgoing, incoming) = try await twoClipFixture()
        _ = try await harness.runOK("apply_transition", args: [
            "outgoingClipId": outgoing.id, "incomingClipId": incoming.id,
            "type": "dipToBlack", "durationFrames": 6,
        ])
        let editor = harness.editor
        #expect(editor.timeline.tracks.filter { $0.type == .video }.count == 1)
        let out = try #require(editor.timeline.tracks.flatMap(\.clips).first { $0.id == outgoing.id })
        #expect(out.opacityTrack?.keyframes.map(\.frame) == [117, 120])
        #expect(out.opacityTrack?.keyframes.map(\.value) == [1, 0])
        let transitionId = try #require(editor.timeline.transitions.first?.id)

        _ = try await harness.runOK("remove_transition", args: ["transitionId": transitionId])
        #expect(editor.timeline.transitions.isEmpty)
        #expect(editor.timeline.tracks.flatMap(\.clips).first { $0.id == outgoing.id }?.opacityTrack == nil)
    }

    @Test func slideMovesTheOverlayAcross() async throws {
        let (harness, outgoing, incoming) = try await twoClipFixture()
        _ = try await harness.runOK("apply_transition", args: [
            "outgoingClipId": outgoing.id, "incomingClipId": incoming.id,
            "type": "slide", "direction": "left", "durationFrames": 8,
        ])
        let overlay = try #require(harness.editor.timeline.tracks.flatMap(\.clips).first {
            $0.mediaType == .video && $0.startFrame == 116
        })
        let positions = try #require(overlay.positionTrack?.keyframes)
        #expect(positions.map(\.frame) == [0, 8])
        #expect(positions.first?.value == AnimPair(a: 1, b: 0))
        #expect(positions.last?.value == AnimPair(a: 0, b: 0))
    }

    @Test func validationRefusesEveryBadRequest() async throws {
        let (harness, outgoing, incoming) = try await twoClipFixture()
        let bad: [(String, [String: Any], String)] = [
            ("unknown clip", ["outgoingClipId": "nope", "incomingClipId": incoming.id, "type": "dissolve", "durationFrames": 4], "not found"),
            ("unknown type", ["outgoingClipId": outgoing.id, "incomingClipId": incoming.id, "type": "wipe", "durationFrames": 4], "dissolve, dipToBlack, slide, push"),
            ("short duration", ["outgoingClipId": outgoing.id, "incomingClipId": incoming.id, "type": "dissolve", "durationFrames": 1], "at least 2"),
            ("direction forbidden", ["outgoingClipId": outgoing.id, "incomingClipId": incoming.id, "type": "dissolve", "direction": "left", "durationFrames": 4], "no direction"),
            ("direction required", ["outgoingClipId": outgoing.id, "incomingClipId": incoming.id, "type": "slide", "durationFrames": 4], "need a direction"),
            ("too long", ["outgoingClipId": outgoing.id, "incomingClipId": incoming.id, "type": "dissolve", "durationFrames": 500], "at most"),
        ]
        for (index, (name, args, expected)) in bad.enumerated() {
            let result = await harness.runRaw("apply_transition", args: args)
            let message = ToolHarness.textOf(result)
            #expect(result.isError, "case \(index) \(name): \(message)")
            #expect(message.contains(expected), "case \(index) \(name): \(message)")
        }
        #expect(harness.editor.timeline.transitions.isEmpty)
    }

    @Test func nonAdjacentClipsAreRefused() async throws {
        let harness = ToolHarness()
        let a = harness.addAsset(type: .video, duration: 8)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": a.id, "startFrame": 0, "source": [0.0, 2.0]],
            ["mediaRef": a.id, "startFrame": 120, "source": [0.0, 2.0]],
        ]])
        let clips = harness.editor.timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .video }
        let result = await harness.runRaw("apply_transition", args: [
            "outgoingClipId": clips[0].id, "incomingClipId": clips[1].id,
            "type": "dissolve", "durationFrames": 4,
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("adjacent"))
    }

    @Test func audioPairsAndMissingHandlesAreRefused() async throws {
        let harness = ToolHarness()
        let a = harness.addAsset(type: .audio, duration: 8)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": a.id, "startFrame": 0, "source": [0.0, 2.0]],
            ["mediaRef": a.id, "startFrame": 60, "source": [2.0, 4.0]],
        ]])
        let clips = harness.editor.timeline.tracks.flatMap(\.clips)
        let audio = await harness.runRaw("apply_transition", args: [
            "outgoingClipId": clips[0].id, "incomingClipId": clips[1].id,
            "type": "dissolve", "durationFrames": 4,
        ])
        #expect(audio.isError)
        #expect(ToolHarness.textOf(audio).contains("video or image"))

        let (harness2, outgoing2, incoming2) = try await twoClipFixture()
        // incoming trimStart is 30; duration 70 needs 35 frames of handle.
        let handles = await harness2.runRaw("apply_transition", args: [
            "outgoingClipId": outgoing2.id, "incomingClipId": incoming2.id,
            "type": "dissolve", "durationFrames": 70,
        ])
        #expect(handles.isError)
        #expect(ToolHarness.textOf(handles).contains("unused source"))
    }

    @Test func secondTransitionOnSameClipsAndUnknownRemovalAreRefused() async throws {
        let (harness, outgoing, incoming) = try await twoClipFixture()
        _ = try await harness.runOK("apply_transition", args: [
            "outgoingClipId": outgoing.id, "incomingClipId": incoming.id,
            "type": "dipToBlack", "durationFrames": 4,
        ])
        let again = await harness.runRaw("apply_transition", args: [
            "outgoingClipId": outgoing.id, "incomingClipId": incoming.id,
            "type": "dipToBlack", "durationFrames": 4,
        ])
        #expect(again.isError)
        #expect(ToolHarness.textOf(again).contains("already has a transition"))
        let unknown = await harness.runRaw("remove_transition", args: ["transitionId": "nope"])
        #expect(unknown.isError)
        #expect(ToolHarness.textOf(unknown).contains("Unknown transitionId"))
    }

    @Test func deletingAClipCascadesItsTransitionAndOverlays() async throws {
        let (harness, outgoing, incoming) = try await twoClipFixture()
        _ = try await harness.runOK("apply_transition", args: [
            "outgoingClipId": outgoing.id, "incomingClipId": incoming.id,
            "type": "dissolve", "durationFrames": 6,
        ])
        #expect(harness.editor.timeline.transitions.count == 1)
        _ = try await harness.runOK("remove_clips", args: ["clipIds": [incoming.id]])
        #expect(harness.editor.timeline.transitions.isEmpty)
        #expect(!harness.editor.timeline.tracks.flatMap(\.clips).contains { $0.startFrame == 117 && $0.mediaType == .video })
    }

    @Test func getTimelineListsTransitionsWithStaleFlags() async throws {
        let (harness, outgoing, incoming) = try await twoClipFixture()
        _ = try await harness.runOK("apply_transition", args: [
            "outgoingClipId": outgoing.id, "incomingClipId": incoming.id,
            "type": "dissolve", "durationFrames": 6,
        ])
        let timeline = try await harness.runOK("get_timeline") as? [String: Any]
        let transitions = try #require(timeline?["transitions"] as? [[String: Any]])
        #expect(transitions.count == 1)
        #expect(transitions[0]["type"] as? String == "dissolve")
        #expect(transitions[0]["stale"] as? Bool == false)
    }

    @Test func endToEndOverMCPWithUndo() async throws {
        let (harness, outgoing, incoming) = try await twoClipFixture()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)
        let server = Server(name: "transition-test", version: "1.0.0", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "transition-test", version: "1.0.0")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            #expect(tools.contains { $0.name == "apply_transition" })
            #expect(tools.contains { $0.name == "remove_transition" })

            let applied = try await client.callTool(name: "apply_transition", arguments: [
                "outgoingClipId": .string(outgoing.id),
                "incomingClipId": .string(incoming.id),
                "type": .string("dipToBlack"),
                "durationFrames": .int(6),
            ])
            #expect(applied.isError != true)
            #expect(harness.editor.timeline.transitions.count == 1)
            print("UNDO-DBG2 canUndo=\(undoManager.canUndo) action=\(undoManager.undoActionName)")

            let undone = try await client.callTool(name: "undo", arguments: [:])
            for item in undone.content { if case .text(let t, _, _) = item { print("UNDO-DBG text=\(t.prefix(200))") } }
            #expect(undone.isError != true)
            #expect(harness.editor.timeline.transitions.isEmpty)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }
}
