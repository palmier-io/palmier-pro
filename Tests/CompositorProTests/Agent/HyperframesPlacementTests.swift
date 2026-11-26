import AppKit
import Foundation
import Testing
@testable import CompositorPro

@Suite("HyperFrames Track Placement & Keyframing")
@MainActor
struct HyperframesPlacementTests {

    private func createTestBlock(id: String = "test-motion-badge", durationFrames: Int = 45) throws -> (URL, HyperframesBlock) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let assetFile = tempDir.appendingPathComponent("badge.png")
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 64,
            pixelsHigh: 64,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 64 * 4,
            bitsPerPixel: 32
        )!
        let pngData = rep.representation(using: .png, properties: [:])!
        try pngData.write(to: assetFile)

        let block = HyperframesBlock(
            id: id,
            name: "Test Motion Badge",
            category: "overlays",
            tags: ["badge", "kinetic"],
            description: "A test kinetic motion badge",
            path: "blocks/\(id)/block.json",
            assets: [assetFile.absoluteString],
            defaultDurationFrames: durationFrames
        )
        return (tempDir, block)
    }

    @Test func insertAndPlaceDirectlyPlacesOnVisualTrackWithPreset() async throws {
        let (tempDir, block) = try createTestBlock()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        HyperframesCatalog.shared.registerBlock(block)
        defer { HyperframesCatalog.shared.unregisterBlock(id: block.id) }

        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack()]))
        let receipt = try await harness.editor.insertAndPlaceHyperframesBlock(
            blockId: block.id,
            startFrame: 15,
            durationFrames: 60,
            motionPreset: .punchIn,
            blendMode: .screen,
            opacity: 0.9,
            scale: 1.1
        )

        #expect(receipt.blockId == block.id)
        #expect(receipt.startFrame == 15)
        #expect(receipt.durationFrames == 60)
        #expect(receipt.motionPreset == "punchIn")
        #expect(!receipt.placedClipIds.isEmpty)

        let placedClip = try #require(harness.editor.clipFor(id: receipt.placedClipIds[0]))
        #expect(placedClip.startFrame == 15)
        #expect(placedClip.durationFrames == 60)
        #expect(placedClip.blendMode == .screen)
        #expect(placedClip.opacity == 0.9)
        #expect(placedClip.scaleTrack?.isActive == true)
        #expect(placedClip.opacityTrack?.isActive == true)
    }

    @Test func slideUpMotionPresetAnimatesPositionAndOpacity() async throws {
        let (tempDir, block) = try createTestBlock()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        HyperframesCatalog.shared.registerBlock(block)
        defer { HyperframesCatalog.shared.unregisterBlock(id: block.id) }

        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack()]))
        let receipt = try await harness.editor.insertAndPlaceHyperframesBlock(
            blockId: block.id,
            startFrame: 0,
            durationFrames: 30,
            motionPreset: .slideUp
        )

        let placedClip = try #require(harness.editor.clipFor(id: receipt.placedClipIds[0]))
        #expect(placedClip.opacityTrack?.isActive == true)
        #expect(placedClip.positionTrack?.isActive == true)
        let firstPos = try #require(placedClip.positionTrack?.keyframes.first?.value)
        let lastPos = try #require(placedClip.positionTrack?.keyframes.last?.value)
        #expect(firstPos.b > lastPos.b)
    }

    @Test func singleAtomicUndoRestoresTimelineAndMediaLibrary() async throws {
        let (tempDir, block) = try createTestBlock()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        HyperframesCatalog.shared.registerBlock(block)
        defer { HyperframesCatalog.shared.unregisterBlock(id: block.id) }

        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack()]))
        let undo = UndoManager()
        harness.editor.undo.attach(undo)

        let clipsBefore = harness.editor.timeline.tracks.flatMap(\.clips).count
        let mediaBefore = harness.editor.mediaAssets.count

        let receipt = try await harness.editor.insertAndPlaceHyperframesBlock(
            blockId: block.id,
            startFrame: 10,
            motionPreset: .fadeIn
        )

        #expect(harness.editor.timeline.tracks.flatMap(\.clips).count == clipsBefore + 1)
        #expect(harness.editor.mediaAssets.count == mediaBefore + 1)
        #expect(undo.canUndo)

        undo.undo()

        #expect(harness.editor.timeline.tracks.flatMap(\.clips).count == clipsBefore)
        #expect(harness.editor.mediaAssets.count == mediaBefore)
        #expect(harness.editor.clipFor(id: receipt.placedClipIds[0]) == nil)
    }

    @Test func toolExecutionViaInsertAndPlaceHyperframesBlock() async throws {
        let (tempDir, block) = try createTestBlock()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        HyperframesCatalog.shared.registerBlock(block)
        defer { HyperframesCatalog.shared.unregisterBlock(id: block.id) }

        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack()]))
        let response = try await harness.runOK("insert_and_place_hyperframes_block", args: [
            "blockId": block.id,
            "startFrame": 24,
            "durationFrames": 40,
            "motionPreset": "gentlePush",
            "blendMode": "overlay"
        ]) as? [String: Any]

        #expect(response?["status"] as? String == "ok")
        #expect(response?["blockId"] as? String == block.id)
        #expect(response?["startFrame"] as? Int == 24)
        #expect(response?["durationFrames"] as? Int == 40)
        #expect(response?["motionPreset"] as? String == "gentlePush")

        let placedIds = response?["placedClipIds"] as? [String] ?? []
        #expect(!placedIds.isEmpty)
        let clip = try #require(harness.editor.timeline.tracks.flatMap(\.clips).first { $0.id.hasPrefix(placedIds[0]) })
        #expect(clip.startFrame == 24)
        #expect(clip.durationFrames == 40)
        #expect(clip.blendMode == .overlay)
        #expect(clip.scaleTrack?.isActive == true)
    }

    @Test func toolExecutionLibraryOnlyWhenPlaceOnTimelineFalse() async throws {
        let (tempDir, block) = try createTestBlock()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        HyperframesCatalog.shared.registerBlock(block)
        defer { HyperframesCatalog.shared.unregisterBlock(id: block.id) }

        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack()]))
        let clipsBefore = harness.editor.timeline.tracks.flatMap(\.clips).count
        let mediaBefore = harness.editor.mediaAssets.count

        let response = try await harness.runOK("insert_hyperframes_block", args: [
            "blockId": block.id,
            "placeOnTimeline": false
        ]) as? [String: Any]

        #expect(response?["status"] as? String == "ok")
        #expect(response?["blockId"] as? String == block.id)
        #expect(harness.editor.mediaAssets.count == mediaBefore + 1)
        #expect(harness.editor.timeline.tracks.flatMap(\.clips).count == clipsBefore)
    }

    @Test func toolExecutionRejectsUnknownBlockId() async throws {
        let harness = ToolHarness()
        let result = await harness.runRaw("insert_and_place_hyperframes_block", args: [
            "blockId": "non-existent-block-id"
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("Unknown HyperFrames block id"))
    }
}
