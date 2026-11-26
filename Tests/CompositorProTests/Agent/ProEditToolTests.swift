import AVFoundation
import CoreGraphics
import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("offset_audio / freeze_clip / sync_to_beats")
@MainActor
struct ProEditToolTests {
    private func linkedPair() async throws -> (ToolHarness, Clip, Clip) {
        let harness = ToolHarness()
        let asset = harness.addAsset(type: .video, duration: 20, hasAudio: true)
        // Placed at frame 30 so an L-cut has a picture to run past.
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": asset.id, "startFrame": 30, "source": [2.0, 6.0]],
        ]])
        let clips = harness.editor.timeline.tracks.flatMap(\.clips)
        let video = try #require(clips.first { $0.mediaType == .video })
        let audio = try #require(clips.first { $0.mediaType == .audio })
        #expect(video.linkGroupId != nil)
        return (harness, video, audio)
    }

    // MARK: - J-cut / L-cut

    @Test func positiveOffsetIsAJCutThatLeadsThePicture() async throws {
        let (harness, video, audio) = try await linkedPair()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)
        let receipt = try await harness.runOK("offset_audio", args: [
            "videoClipId": video.id, "offsetFrames": 18,
        ]) as? [String: Any]
        #expect(receipt?["kind"] as? String == "jCut")
        #expect(receipt?["offsetFrames"] as? Int == 18)
        #expect(receipt?["undoSteps"] as? Int == 1)

        let moved = try #require(harness.editor.clipFor(id: audio.id))
        #expect(moved.startFrame == audio.startFrame - 18)
        // Advancing the head consumes the source it now plays from.
        #expect(moved.trimStartFrame == audio.trimStartFrame + 18)
        // The link survives, so the pair still travels together.
        #expect(moved.linkGroupId == video.linkGroupId)

        undoManager.undo()
        #expect(harness.editor.clipFor(id: audio.id)?.startFrame == audio.startFrame)
        #expect(harness.editor.clipFor(id: audio.id)?.trimStartFrame == audio.trimStartFrame)
    }

    @Test func negativeOffsetIsAnLCutThatHoldsPastThePicture() async throws {
        let (harness, video, audio) = try await linkedPair()
        let receipt = try await harness.runOK("offset_audio", args: [
            "videoClipId": video.id, "offsetFrames": -24,
        ]) as? [String: Any]
        #expect(receipt?["kind"] as? String == "lCut")
        let moved = try #require(harness.editor.clipFor(id: audio.id))
        // An L-cut runs the outgoing sound past its own picture: the tail extends.
        #expect(moved.startFrame == audio.startFrame)
        #expect(moved.endFrame == audio.endFrame + 24)
        #expect(moved.durationFrames == audio.durationFrames + 24)
        // Extending the tail gives back the tail trim it was holding.
        #expect(moved.trimEndFrame == audio.trimEndFrame - 24)
    }

    @Test func clearLocksPictureAndSoundBackTogether() async throws {
        let (harness, video, _) = try await linkedPair()
        _ = try await harness.runOK("offset_audio", args: ["videoClipId": video.id, "offsetFrames": 15])
        let cleared = try await harness.runOK("offset_audio", args: [
            "videoClipId": video.id, "clear": true,
        ]) as? [String: Any]
        #expect(cleared?["kind"] as? String == "none")
        #expect(cleared?["offsetFrames"] as? Int == 0)
        // An L-cut is a tail change, so picture and sound match again.
        let restored = try #require(harness.editor.clipFor(id: video.id))
        #expect(restored.linkGroupId != nil)
        let audio = try #require(harness.editor.timeline.tracks.flatMap(\.clips)
            .first { $0.mediaType == .audio })
        #expect(audio.endFrame <= restored.endFrame + 1)
    }

    @Test func offsettingTwiceIsRefusedNotStacked() async throws {
        let (harness, video, _) = try await linkedPair()
        _ = try await harness.runOK("offset_audio", args: ["videoClipId": video.id, "offsetFrames": 10])
        let again = await harness.runRaw("offset_audio", args: [
            "videoClipId": video.id, "offsetFrames": 10,
        ])
        #expect(again.isError)
        #expect(ToolHarness.textOf(again).contains("already offset"))
    }

    @Test func offsetLongerThanTheClipIsRefused() async throws {
        let (harness, video, _) = try await linkedPair()
        let result = await harness.runRaw("offset_audio", args: [
            "videoClipId": video.id, "offsetFrames": 5000,
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("no audio on the other side"))
    }

    @Test func offsettingPastTheStartOfTheTimelineIsRefused() async throws {
        let (harness, video, _) = try await linkedPair()
        let result = await harness.runRaw("offset_audio", args: [
            "videoClipId": video.id, "offsetFrames": -5000,
        ])
        #expect(result.isError)
    }

    @Test func aJCutCannotStartBeforeFrameZero() async throws {
        let harness = ToolHarness()
        let asset = harness.addAsset(type: .video, duration: 20, hasAudio: true)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": asset.id, "startFrame": 0, "source": [0.0, 3.0]],
        ]])
        let video = try #require(harness.editor.timeline.tracks.flatMap(\.clips)
            .first { $0.mediaType == .video })
        let result = await harness.runRaw("offset_audio", args: [
            "videoClipId": video.id, "offsetFrames": 30,
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("exceeds the available room"))
    }

    @Test func anUnlinkedClipIsRefusedWithAnActionableMessage() async throws {
        let harness = ToolHarness()
        let asset = harness.addAsset(type: .video, duration: 20)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": asset.id, "startFrame": 0, "source": [0.0, 2.0]],
        ]])
        let video = try #require(harness.editor.timeline.tracks.flatMap(\.clips).first)
        #expect(video.linkGroupId == nil)
        let result = await harness.runRaw("offset_audio", args: [
            "videoClipId": video.id, "offsetFrames": 10,
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("no linked audio partner"))
    }

    @Test func offsetAudioRejectsAnUnknownClip() async throws {
        let harness = ToolHarness()
        let result = await harness.runRaw("offset_audio", args: [
            "videoClipId": "nope", "offsetFrames": 10,
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("Clip not found"))
    }

    // MARK: - Freeze frame

    private func clipForFreeze() async throws -> (ToolHarness, Clip) {
        let harness = ToolHarness()
        let asset = harness.addAsset(type: .video, duration: 20, hasAudio: true)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": asset.id, "startFrame": 0, "source": [0.0, 5.0]],
        ]])
        let video = try #require(harness.editor.timeline.tracks.flatMap(\.clips)
            .first { $0.mediaType == .video })
        return (harness, video)
    }

    @Test func freezeHoldsThePictureAndLeavesAudioAlone() async throws {
        let (harness, video) = try await clipForFreeze()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)
        let lengthBefore = video.durationFrames
        let endBefore = video.endFrame

        let receipt = try await harness.runOK("freeze_clip", args: [
            "clipId": video.id, "freezeFrames": 15, "atFrame": 60,
        ]) as? [String: Any]
        #expect(receipt?["freezeFrames"] as? Int == 15)
        #expect(receipt?["audioKeepsPlaying"] as? Bool == true)
        #expect(receipt?["frozenFrame"] as? Int == 60)
        // The hold sits at the clip's head; atFrame picks the picture it shows.
        #expect(receipt?["freezeStartFrame"] as? Int == video.startFrame)

        let frozen = try #require(harness.editor.clipFor(id: video.id))
        #expect(frozen.freezeFrames == 15)
        #expect(frozen.startFrame == video.startFrame)
        #expect(frozen.endFrame == endBefore + 15)
        #expect(frozen.durationFrames == lengthBefore + 15)
        // A hold reads no source, so the source span is unchanged.
        #expect(frozen.sourceFramesConsumed == video.sourceFramesConsumed)
        // The linked audio partner is not touched at all.
        let audio = try #require(harness.editor.timeline.tracks.flatMap(\.clips)
            .first { $0.mediaType == .audio })
        #expect(audio.durationFrames == video.durationFrames)
        #expect(audio.startFrame == video.startFrame)

        undoManager.undo()
        let reverted = try #require(harness.editor.clipFor(id: video.id))
        #expect(reverted.freezeFrames == 0)
        #expect(reverted.endFrame == endBefore)
    }

    @Test func freezeRefusesToSwallowTheWholeClip() async throws {
        let (harness, video) = try await clipForFreeze()
        let result = await harness.runRaw("freeze_clip", args: [
            "clipId": video.id, "freezeFrames": 100_000, "atFrame": 5,
        ])
        #expect(result.isError)
        #expect(harness.editor.clipFor(id: video.id)?.freezeFrames == 0)
    }

    @Test func freezeRefusesAFramePastTheClip() async throws {
        let (harness, video) = try await clipForFreeze()
        let result = await harness.runRaw("freeze_clip", args: [
            "clipId": video.id, "freezeFrames": 10, "atFrame": 99_999,
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("outside the clip"))
    }

    @Test func clearingAFreezeRestoresTheLength() async throws {
        let (harness, video) = try await clipForFreeze()
        let endBefore = video.endFrame
        _ = try await harness.runOK("freeze_clip", args: [
            "clipId": video.id, "freezeFrames": 12, "atFrame": 30,
        ])
        let receipt = try await harness.runOK("freeze_clip", args: [
            "clipId": video.id, "clear": true,
        ]) as? [String: Any]
        #expect(receipt?["freezeFrames"] as? Int == 0)
        #expect(harness.editor.clipFor(id: video.id)?.endFrame == endBefore)
    }

    @Test func clearingAFreezeThatIsNotThereIsRefused() async throws {
        let (harness, video) = try await clipForFreeze()
        let result = await harness.runRaw("freeze_clip", args: ["clipId": video.id, "clear": true])
        #expect(result.isError)
    }

    // MARK: - Beat sync

    private func beatFixture() async throws -> (ToolHarness, Clip) {
        let harness = ToolHarness()
        let music = harness.addAsset(type: .audio, duration: 30)
        harness.editor.mediaVisualCache.beats.seedForTesting(music.id, BeatAnalysis(
            bpm: 120,
            beats: [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0],
            downbeats: [0.0, 2.0, 4.0]
        ))
        let video = harness.addAsset(type: .video, duration: 20)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": video.id, "startFrame": 0, "source": [0.0, 6.0]],
        ]])
        let clip = try #require(harness.editor.timeline.tracks.flatMap(\.clips)
            .first { $0.mediaType == .video })
        return (harness, clip)
    }

    @Test func syncingCutsTheClipOnEveryBeat() async throws {
        let (harness, clip) = try await beatFixture()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)
        let receipt = try await harness.runOK("sync_to_beats", args: [
            "mediaRef": musicRef(of: harness), "clipId": clip.id,
        ]) as? [String: Any]
        #expect(receipt?["changed"] as? Bool == true)
        let cuts = try #require(receipt?["cuts"] as? [[String: Any]])
        #expect(cuts.count == 10)
        // 120bpm at 30fps is a beat every 15 frames.
        #expect(cuts[0]["frame"] as? Int == 15)
        #expect(cuts[0]["snappedBy"] as? Int == 0)
        #expect(cuts[1]["frame"] as? Int == 30)
        let onTrack = harness.editor.timeline.tracks.flatMap(\.clips)
            .filter { $0.mediaType == .video }
        #expect(onTrack.count == 11)

        undoManager.undo()
        #expect(harness.editor.timeline.tracks.flatMap(\.clips)
            .filter { $0.mediaType == .video }.count == 1)
    }

    @Test func downbeatModeUsesBarsNotBeats() async throws {
        let (harness, clip) = try await beatFixture()
        let receipt = try await harness.runOK("sync_to_beats", args: [
            "mediaRef": musicRef(of: harness), "clipId": clip.id, "useDownbeats": true,
        ]) as? [String: Any]
        #expect(receipt?["usedDownbeats"] as? Bool == true)
        let cuts = try #require(receipt?["cuts"] as? [[String: Any]])
        // Downbeats at 0s, 2s, 4s → frames 0, 60, 120; frame 0 is the clip start, so it is skipped.
        #expect(cuts.map { $0["frame"] as? Int } == [60, 120])
    }

    @Test func explicitBeatIndicesAreHonoured() async throws {
        let (harness, clip) = try await beatFixture()
        let receipt = try await harness.runOK("sync_to_beats", args: [
            "mediaRef": musicRef(of: harness), "clipId": clip.id, "beats": [2, 6],
        ]) as? [String: Any]
        let cuts = try #require(receipt?["cuts"] as? [[String: Any]])
        #expect(cuts.map { $0["frame"] as? Int } == [30, 90])
    }

    @Test func anOutOfRangeBeatIndexIsRefused() async throws {
        let (harness, clip) = try await beatFixture()
        let result = await harness.runRaw("sync_to_beats", args: [
            "mediaRef": musicRef(of: harness), "clipId": clip.id, "beats": [99],
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("out of range"))
    }

    @Test func mediaWithNoBeatAnalysisIsRefusedWithTheNextStep() async throws {
        let (harness, clip) = try await beatFixture()
        let result = await harness.runRaw("sync_to_beats", args: [
            "mediaRef": "no-such-asset", "clipId": clip.id,
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("detect_beats"))
    }

    @Test func aClipWithNoBeatsInsideItIsRefusedWithoutCutting() async throws {
        let harness = ToolHarness()
        let music = harness.addAsset(type: .audio, duration: 30)
        harness.editor.mediaVisualCache.beats.seedForTesting(music.id, BeatAnalysis(
            bpm: 120, beats: [100.0, 100.5, 101.0], downbeats: [100.0]
        ))
        let video = harness.addAsset(type: .video, duration: 20)
        _ = try await harness.runOK("add_clips", args: ["entries": [
            ["mediaRef": video.id, "startFrame": 0, "source": [0.0, 2.0]],
        ]])
        let clip = try #require(harness.editor.timeline.tracks.flatMap(\.clips)
            .first { $0.mediaType == .video })
        let result = await harness.runRaw("sync_to_beats", args: [
            "mediaRef": music.id, "clipId": clip.id,
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("nothing to cut"))
        #expect(harness.editor.timeline.tracks.flatMap(\.clips)
            .filter { $0.mediaType == .video }.count == 1)
    }

    @Test func syncRejectsMissingArguments() async throws {
        let (harness, clip) = try await beatFixture()
        for args in [["clipId": clip.id], ["mediaRef": musicRef(of: harness)]] {
            let result = await harness.runRaw("sync_to_beats", args: args)
            #expect(result.isError)
        }
    }

    private func musicRef(of harness: ToolHarness) -> String {
        harness.editor.mediaAssets.first { $0.type == .audio }?.id ?? ""
    }

    // MARK: - MCP boundary

    @Test func endToEndOverMCP() async throws {
        let (harness, video) = try await clipForFreeze()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)
        let server = Server(name: "pro-edit", version: "1.0.0", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "pro-edit", version: "1.0.0")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            for name in ["offset_audio", "freeze_clip", "sync_to_beats"] {
                #expect(tools.contains { $0.name == name }, "missing \(name)")
            }
            let frozen = try await client.callTool(name: "freeze_clip", arguments: [
                "clipId": .string(video.id), "freezeFrames": .int(10), "atFrame": .int(30),
            ])
            #expect(frozen.isError != true)
            #expect(harness.editor.clipFor(id: video.id)?.freezeFrames == 10)
            let undone = try await client.callTool(name: "undo", arguments: [:])
            #expect(undone.isError != true)
            #expect(harness.editor.clipFor(id: video.id)?.freezeFrames == 0)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }
}
