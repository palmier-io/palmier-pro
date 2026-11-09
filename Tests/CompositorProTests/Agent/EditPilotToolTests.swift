import Foundation
import Testing
@testable import CompositorPro

@Suite("EditPilot planner tool")
@MainActor
struct EditPilotToolTests {

    private func makeHarnessWithMedia(count: Int = 4, hasMusic: Bool = true) -> (ToolHarness, [MediaAsset], MediaAsset?) {
        let harness = ToolHarness()
        var visualAssets: [MediaAsset] = []
        for i in 1...count {
            let asset = harness.makeAsset(name: "Scene_\(i).mp4", type: .video, duration: 10.0)
            visualAssets.append(asset)
        }
        var musicAsset: MediaAsset? = nil
        if hasMusic {
            musicAsset = harness.makeAsset(name: "Upbeat_Summer_Track.mp3", type: .audio, duration: 60.0)
            // Seed deterministic beats into beat cache
            let beats: [Double] = [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 5.5, 6.0, 6.5, 7.0, 7.5, 8.0]
            let downbeats: [Double] = [0.0, 2.0, 4.0, 6.0, 8.0]
            let analysis = BeatAnalysis(bpm: 120.0, beats: beats, downbeats: downbeats)
            harness.editor.mediaVisualCache.beats.seedForTesting(musicAsset!.id, analysis)
        }
        return (harness, visualAssets, musicAsset)
    }

    @Test("Proposes arrangement from creative direction with beat sync and captions")
    func proposeArrangementFromDirection() async throws {
        let (harness, visuals, music) = makeHarnessWithMedia(count: 3, hasMusic: true)

        let result = try #require(
            try await harness.runOK("edit_pilot", args: [
                "action": "propose",
                "direction": "fast-paced social summary with upbeat music sync",
                "targetDurationSeconds": 15.0,
            ]) as? [String: Any]
        )

        let arrangementId = try #require(result["id"] as? String)
        #expect(!arrangementId.isEmpty)
        #expect(result["status"] as? String == "proposed")
        #expect(result["pacing"] as? String == "fast")

        let blocks = try #require(result["blocks"] as? [[String: Any]])
        #expect(blocks.count == 3) // Limited to 3 unique visual assets

        // First block is hook
        #expect(blocks[0]["captionRole"] as? String == "hook")
        #expect(blocks[0]["caption"] as? String == "Quick Social Summary")
        #expect(blocks[0]["isApproved"] as? Bool == false)

        // Last block is CTA
        #expect(blocks[2]["captionRole"] as? String == "cta")
        #expect(blocks[2]["caption"] as? String == "Follow & Save For More")

        // Music track detected and attached
        let musicTrack = try #require(result["musicTrack"] as? [String: Any])
        #expect(musicTrack["mediaRef"] as? String == music?.id)
        #expect(musicTrack["bpm"] as? Double == 120.0)

        // Check visual uniqueness: each block has a distinct mediaRef
        let refs = blocks.compactMap { $0["mediaRef"] as? String }
        #expect(Set(refs).count == blocks.count)
        #expect(refs == visuals.map(\.id))
    }

    @Test("Enforces visual uniqueness — never reuses an image/video source within arrangement")
    func enforcesVisualUniqueness() async throws {
        let (harness, visuals, _) = makeHarnessWithMedia(count: 2, hasMusic: false)

        // Request proposal with duplicate mediaRef
        let result = try #require(
            try await harness.runOK("edit_pilot", args: [
                "action": "propose",
                "direction": "upbeat product showcase",
                "mediaRefs": [visuals[0].id, visuals[0].id, visuals[1].id, visuals[0].id],
            ]) as? [String: Any]
        )

        let blocks = try #require(result["blocks"] as? [[String: Any]])
        #expect(blocks.count == 2) // Deduplicated to 2 unique assets
        let usedRefs = blocks.compactMap { $0["mediaRef"] as? String }
        #expect(Set(usedRefs).count == 2)
    }

    @Test("Review workflow: approve block, edit trim, approve all")
    func reviewAndApprovalWorkflow() async throws {
        let (harness, _, _) = makeHarnessWithMedia(count: 3, hasMusic: false)

        let proposeResult = try #require(
            try await harness.runOK("edit_pilot", args: [
                "action": "propose",
                "direction": "cinematic overview",
            ]) as? [String: Any]
        )
        let arrangementId = try #require(proposeResult["id"] as? String)
        let blocks = try #require(proposeResult["blocks"] as? [[String: Any]])
        let block0Id = try #require(blocks[0]["id"] as? String)

        // Review block 0: approve and adjust caption and trim
        let reviewResult = try #require(
            try await harness.runOK("edit_pilot", args: [
                "action": "review",
                "arrangementId": arrangementId,
                "blockId": block0Id,
                "isApproved": true,
                "sourceStartSeconds": 2.0,
                "sourceEndSeconds": 5.0,
                "caption": "Custom Opening Scene",
            ]) as? [String: Any]
        )
        #expect(reviewResult["status"] as? String == "partially_approved")
        let reviewedBlocks = try #require(reviewResult["blocks"] as? [[String: Any]])
        #expect(reviewedBlocks[0]["isApproved"] as? Bool == true)
        #expect(reviewedBlocks[0]["caption"] as? String == "Custom Opening Scene")
        #expect(reviewedBlocks[0]["durationSeconds"] as? Double == 3.0)

        // Approve all blocks
        let approveAllResult = try #require(
            try await harness.runOK("edit_pilot", args: [
                "action": "approve_all",
                "arrangementId": arrangementId,
            ]) as? [String: Any]
        )
        #expect(approveAllResult["status"] as? String == "approved")
        let allBlocks = try #require(approveAllResult["blocks"] as? [[String: Any]])
        #expect(allBlocks.allSatisfy { ($0["isApproved"] as? Bool) == true })
    }

    @Test("Applies approved arrangement to timeline in one atomic undo step")
    func applyArrangementInOneUndoAction() async throws {
        let (harness, _, music) = makeHarnessWithMedia(count: 3, hasMusic: true)

        let proposeResult = try #require(
            try await harness.runOK("edit_pilot", args: [
                "action": "propose",
                "direction": "fast-paced social summary with upbeat music sync",
            ]) as? [String: Any]
        )
        let arrangementId = try #require(proposeResult["id"] as? String)

        // Applying without approval fails
        let unapprovedRun = await harness.runRaw("edit_pilot", args: [
            "action": "apply",
            "arrangementId": arrangementId,
        ])
        #expect(unapprovedRun.isError)
        #expect(ToolHarness.textOf(unapprovedRun).contains("No approved blocks"))

        // Approve all blocks
        _ = try await harness.runOK("edit_pilot", args: [
            "action": "approve_all",
            "arrangementId": arrangementId,
        ])

        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)

        let initialTimelineTracksCount = harness.editor.timeline.tracks.count

        // Apply approved arrangement
        let applyReceipt = try #require(
            try await harness.runOK("edit_pilot", args: [
                "action": "apply",
                "arrangementId": arrangementId,
            ]) as? [String: Any]
        )

        #expect(applyReceipt["status"] as? String == "applied")
        #expect(applyReceipt["blockCount"] as? Int == 3)
        #expect(applyReceipt["undoable"] as? Bool == true)

        let videoClipIds = try #require(applyReceipt["createdVideoClipIds"] as? [String])
        let textClipIds = try #require(applyReceipt["createdTextClipIds"] as? [String])
        let audioClipIds = try #require(applyReceipt["createdAudioClipIds"] as? [String])
        #expect(videoClipIds.count == 3)
        #expect(!textClipIds.isEmpty)
        #expect(audioClipIds.count == 1)

        // Check timeline state
        #expect(harness.editor.timeline.tracks.count > initialTimelineTracksCount)
        let allClips = harness.editor.timeline.tracks.flatMap(\.clips)
        #expect(allClips.contains { $0.id == videoClipIds[0] })
        #expect(allClips.contains { $0.id == textClipIds[0] })
        #expect(allClips.contains { $0.mediaRef == music?.id })

        // Check undo capability: exactly one undo step reverses the entire arrangement
        #expect(undoManager.canUndo)
        undoManager.undo()

        #expect(harness.editor.timeline.tracks.count == initialTimelineTracksCount)
        let clipsAfterUndo = harness.editor.timeline.tracks.flatMap(\.clips)
        #expect(!clipsAfterUndo.contains { $0.id == videoClipIds[0] })

        // Redo restores everything
        #expect(undoManager.canRedo)
        undoManager.redo()
        let clipsAfterRedo = harness.editor.timeline.tracks.flatMap(\.clips)
        #expect(clipsAfterRedo.contains { $0.id == videoClipIds[0] })
    }

    @Test("Error cases: empty library, invalid trims, nonexistent arrangement")
    func errorHandlingCases() async throws {
        let harness = ToolHarness() // Empty library

        // Empty library
        let emptyRun = await harness.runRaw("edit_pilot", args: [
            "action": "propose",
            "direction": "fast summary",
        ])
        #expect(emptyRun.isError)
        #expect(ToolHarness.textOf(emptyRun).contains("No visual media"))

        // Nonexistent arrangement read
        let notFoundRun = await harness.runRaw("edit_pilot", args: [
            "action": "read",
            "arrangementId": "unknown-id",
        ])
        #expect(notFoundRun.isError)
        #expect(ToolHarness.textOf(notFoundRun).contains("not found"))

        // Invalid trim range (start >= end)
        let (harnessWithMedia, _, _) = makeHarnessWithMedia(count: 2)
        let prop = try #require(
            try await harnessWithMedia.runOK("edit_pilot", args: [
                "action": "propose",
                "direction": "fast summary",
            ]) as? [String: Any]
        )
        let arrId = try #require(prop["id"] as? String)
        let blocks = try #require(prop["blocks"] as? [[String: Any]])
        let blkId = try #require(blocks[0]["id"] as? String)

        let badTrimRun = await harnessWithMedia.runRaw("edit_pilot", args: [
            "action": "review",
            "arrangementId": arrId,
            "blockId": blkId,
            "sourceStartSeconds": 5.0,
            "sourceEndSeconds": 2.0,
        ])
        #expect(badTrimRun.isError)
        #expect(ToolHarness.textOf(badTrimRun).contains("Invalid source trim"))
    }
}
