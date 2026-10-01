import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("crossfade_audio / duck_audio")
@MainActor
struct AudioMixToolTests {
    private func adjacentAudioFixture() async throws -> (ToolHarness, Clip, Clip) {
        let harness = ToolHarness()
        let a = harness.addAsset(type: .audio, duration: 10)
        let b = harness.addAsset(type: .audio, duration: 10)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": a.id, "startFrame": 0, "source": [0.0, 4.0]],
            ["mediaRef": b.id, "startFrame": 120, "source": [0.0, 4.0]],
        ]])
        let clips = harness.editor.timeline.tracks.flatMap(\.clips)
            .filter { $0.mediaType == .audio }
            .sorted { $0.startFrame < $1.startFrame }
        #expect(clips.count == 2)
        return (harness, clips[0], clips[1])
    }

    @Test func smoothCrossfadeWritesMatchedFadesAsOneUndoStep() async throws {
        let (harness, outgoing, incoming) = try await adjacentAudioFixture()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)

        let receipt = try await harness.runOK("crossfade_audio", args: [
            "outgoingClipId": outgoing.id, "incomingClipId": incoming.id,
            "durationFrames": 24, "curve": "smooth",
        ]) as? [String: Any]
        #expect(receipt?["curve"] as? String == "smooth")
        #expect(receipt?["cutFrame"] as? Int == 120)

        let clips = harness.editor.timeline.tracks.flatMap(\.clips)
        let after = try #require(clips.first { $0.id == outgoing.id })
        let before = try #require(clips.first { $0.id == incoming.id })
        #expect(after.fadeOutFrames == 24)
        #expect(after.fadeOutInterpolation == .smooth)
        #expect(before.fadeInFrames == 24)
        #expect(before.fadeInInterpolation == .smooth)
        #expect(after.volumeTrack == nil)
        #expect(before.volumeTrack == nil)

        undoManager.undo()
        let reverted = harness.editor.timeline.tracks.flatMap(\.clips)
        #expect(reverted.first { $0.id == outgoing.id }?.fadeOutFrames == 0)
        #expect(reverted.first { $0.id == incoming.id }?.fadeInFrames == 0)
    }

    @Test func equalPowerCrossfadeHoldsLoudnessThroughTheOverlap() async throws {
        let (harness, outgoing, incoming) = try await adjacentAudioFixture()
        let receipt = try await harness.runOK("crossfade_audio", args: [
            "outgoingClipId": outgoing.id, "incomingClipId": incoming.id,
            "durationFrames": 48, "curve": "equalPower",
        ]) as? [String: Any]
        #expect(receipt?["curve"] as? String == "equalPower")
        #expect((receipt?["equalPowerSamples"] as? Int ?? 0) > 8)

        let clips = harness.editor.timeline.tracks.flatMap(\.clips)
        let tail = try #require(clips.first { $0.id == outgoing.id }?.volumeTrack)
        let head = try #require(clips.first { $0.id == incoming.id }?.volumeTrack)
        // Both envelopes occupy the last `durationFrames` of their own clip.
        #expect(tail.keyframes.first?.frame == 72)
        #expect(head.keyframes.first?.frame == 72)
        #expect(tail.keyframes.map(\.frame) == head.keyframes.map(\.frame))
        for (a, b) in zip(tail.keyframes, head.keyframes) {
            #expect(abs(a.value * a.value + b.value * b.value - 1) < 1e-6)
        }
    }

    @Test func equalPowerRefusesAnEdgeThatAlreadyHasAFade() async throws {
        let (harness, outgoing, incoming) = try await adjacentAudioFixture()
        _ = try await harness.runOK("set_clip_properties", args: [
            "clipIds": [outgoing.id], "fadeOutFrames": 10,
        ])
        let result = await harness.runRaw("crossfade_audio", args: [
            "outgoingClipId": outgoing.id, "incomingClipId": incoming.id,
            "durationFrames": 12, "curve": "equalPower",
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("already has a fade"))
    }

    @Test func crossfadeRefusesBadRequestsWithoutMutating() async throws {
        let (harness, outgoing, incoming) = try await adjacentAudioFixture()
        let secondAudioTrack = harness.editor.insertTrack(
            at: harness.editor.timeline.tracks.count, type: .audio
        )
        let foreign = harness.addAsset(type: .audio, duration: 5)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": foreign.id, "startFrame": 0, "source": [0.0, 1.0], "trackIndex": secondAudioTrack],
        ]])
        let foreignClip = try #require(harness.editor.timeline.tracks.flatMap(\.clips)
            .first { $0.mediaRef == foreign.id })

        let cases: [(String, [String: Any], String)] = [
            ("same clip", ["outgoingClipId": outgoing.id, "incomingClipId": outgoing.id], "two different clips"),
            ("unknown clip", ["outgoingClipId": "nope", "incomingClipId": incoming.id], "Clip not found"),
            ("other track", ["outgoingClipId": outgoing.id, "incomingClipId": foreignClip.id], "same track"),
            ("duration too long", ["outgoingClipId": outgoing.id, "incomingClipId": incoming.id, "durationFrames": 5000], "exceeds"),
            ("bad curve", ["outgoingClipId": outgoing.id, "incomingClipId": incoming.id, "curve": "wipe"], "curve must be one of"),
        ]
        for (index, testCase) in cases.enumerated() {
            let result = await harness.runRaw("crossfade_audio", args: testCase.1)
            let message = ToolHarness.textOf(result)
            #expect(result.isError, "case \(index) \(testCase.0): \(message)")
            #expect(message.contains(testCase.2), "case \(index) \(testCase.0): \(message)")
        }
        #expect(harness.editor.timeline.tracks.flatMap(\.clips).allSatisfy {
            $0.fadeInFrames == 0 && $0.fadeOutFrames == 0 && $0.volumeTrack == nil
        })
    }

    @Test func gapBetweenClipsIsNotCrossfaded() async throws {
        let harness = ToolHarness()
        let a = harness.addAsset(type: .audio, duration: 10)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": a.id, "startFrame": 0, "source": [0.0, 2.0]],
            ["mediaRef": a.id, "startFrame": 180, "source": [2.0, 4.0]],
        ]])
        let clips = harness.editor.timeline.tracks.flatMap(\.clips)
            .filter { $0.mediaType == .audio }.sorted { $0.startFrame < $1.startFrame }
        let result = await harness.runRaw("crossfade_audio", args: [
            "outgoingClipId": clips[0].id, "incomingClipId": clips[1].id,
            "durationFrames": 12,
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("adjacent"))
    }

    // MARK: - Ducking

    private func bedWithDialogue() async throws -> (ToolHarness, Clip, Clip) {
        let harness = ToolHarness()
        let bed = harness.addAsset(type: .audio, duration: 20)
        let dialogue = harness.addAsset(type: .audio, duration: 20)
        // Overlapping audio needs two lanes: one audio track holds a single clip at a time.
        let dialogueTrack = harness.editor.insertTrack(
            at: harness.editor.timeline.tracks.count, type: .audio
        )
        let bedTrack = harness.editor.insertTrack(at: dialogueTrack + 1, type: .audio)
        #expect(bedTrack != dialogueTrack)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": dialogue.id, "startFrame": 60, "source": [2.0, 5.0], "trackIndex": dialogueTrack],
            ["mediaRef": bed.id, "startFrame": 0, "source": [0.0, 10.0], "trackIndex": bedTrack],
        ]])
        let clips = harness.editor.timeline.tracks.flatMap(\.clips)
        let bedClip = try #require(clips.first { $0.mediaRef == bed.id })
        let dialogueClip = try #require(clips.first { $0.mediaRef == dialogue.id })
        return (harness, bedClip, dialogueClip)
    }

    @Test func duckingWritesAnEnvelopeAndReportsMissingDetection() async throws {
        let (harness, bed, dialogue) = try await bedWithDialogue()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)

        let receipt = try await harness.runOK("duck_audio", args: [
            "bedClipId": bed.id, "duckDb": -9, "attackFrames": 5,
            "holdFrames": 3, "releaseFrames": 12,
        ]) as? [String: Any]
        // Receipts echo the shortened id form, which every clip tool accepts back as input.
        let echoedId = try #require(receipt?["bedClipId"] as? String)
        _ = try await harness.runOK("set_clip_properties", args: [
            "clipIds": [echoedId], "fadeInFrames": 0,
        ])
        #expect(receipt?["duckDb"] as? Double == -9)
        #expect(receipt?["speechDetection"] as? String == "unavailable")
        let ranges = try #require(receipt?["duckedRanges"] as? [[String: Any]])
        #expect(ranges.count == 1)
        // No detection for the stub file, so the whole dialogue clip counts as speech.
        #expect(ranges[0]["startFrame"] as? Int == 55)
        #expect(ranges[0]["endFrame"] as? Int == 162)

        let updated = try #require(harness.editor.timeline.tracks.flatMap(\.clips)
            .first { $0.id == bed.id }?.volumeTrack)
        // Speech runs 60–150; attack starts 5 frames early, hold ends 3 frames after speech,
        // release lands 12 frames later.
        #expect(updated.keyframes.map(\.frame) == [55, 63, 150, 162])
        #expect(abs(updated.keyframes[0].value - 1) < 1e-9)
        #expect(abs(updated.keyframes[1].value - pow(10, -9.0 / 20)) < 1e-6)

        undoManager.undo()
        #expect(harness.editor.timeline.tracks.flatMap(\.clips).first { $0.id == bed.id }?.volumeTrack == nil)
        #expect(dialogue.mediaType == .audio)
    }

    @Test func duckingRefusesToStackOnAnExistingEnvelopeUnlessOverwriting() async throws {
        let (harness, bed, _) = try await bedWithDialogue()
        _ = try await harness.runOK("duck_audio", args: ["bedClipId": bed.id])

        let again = await harness.runRaw("duck_audio", args: ["bedClipId": bed.id])
        #expect(again.isError)
        #expect(ToolHarness.textOf(again).contains("already has volume keyframes"))

        let overwritten = try await harness.runOK("duck_audio", args: [
            "bedClipId": bed.id, "duckDb": -18, "overwrite": true,
        ]) as? [String: Any]
        #expect(overwritten?["changed"] as? Bool == true)
        let track = try #require(harness.editor.timeline.tracks.flatMap(\.clips)
            .first { $0.id == bed.id }?.volumeTrack)
        #expect(abs(track.keyframes[1].value - pow(10, -18.0 / 20)) < 1e-6)
    }

    @Test func duckingRejectsTheBedAsItsOwnSource() async throws {
        let (harness, bed, _) = try await bedWithDialogue()
        let result = await harness.runRaw("duck_audio", args: [
            "bedClipId": bed.id, "sourceClipIds": [bed.id],
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("cannot duck under itself"))
    }

    @Test func duckingRefusesWhenNothingOverlapsTheBed() async throws {
        let harness = ToolHarness()
        let bed = harness.addAsset(type: .audio, duration: 20)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": bed.id, "startFrame": 0, "source": [0.0, 5.0]],
        ]])
        let clip = try #require(harness.editor.timeline.tracks.flatMap(\.clips).first)
        let result = await harness.runRaw("duck_audio", args: ["bedClipId": clip.id])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("No dialogue audio overlaps"))
    }

    @Test func duckingRejectsNonFiniteDecibels() async throws {
        let (harness, bed, _) = try await bedWithDialogue()
        let result = await harness.runRaw("duck_audio", args: [
            "bedClipId": bed.id, "duckDb": "loud",
        ])
        #expect(result.isError)
    }

    @Test func endToEndOverMCPWithUndo() async throws {
        let (harness, bed, _) = try await bedWithDialogue()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)
        let server = Server(name: "audio-mix-test", version: "1.0.0", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "audio-mix-test", version: "1.0.0")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            #expect(tools.contains { $0.name == "duck_audio" })
            #expect(tools.contains { $0.name == "crossfade_audio" })

            let applied = try await client.callTool(name: "duck_audio", arguments: [
                "bedClipId": .string(bed.id), "duckDb": .double(-12),
            ])
            #expect(applied.isError != true)
            let readBack = try await client.callTool(name: "get_timeline", arguments: [:])
            #expect(readBack.isError != true)

            let undone = try await client.callTool(name: "undo", arguments: [:])
            #expect(undone.isError != true)
            #expect(harness.editor.timeline.tracks.flatMap(\.clips)
                .first { $0.id == bed.id }?.volumeTrack == nil)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }
}
