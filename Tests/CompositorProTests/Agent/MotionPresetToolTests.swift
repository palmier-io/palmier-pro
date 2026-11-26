import Foundation
import Testing
@testable import CompositorPro

@Suite("apply_motion_preset")
@MainActor
struct MotionPresetToolTests {
    private func fixture() async throws -> (ToolHarness, Clip) {
        let harness = ToolHarness()
        let asset = harness.addAsset(type: .video, duration: 10)
        _ = try await harness.runOK("add_clips", args: ["entries": [[
            "mediaRef": asset.id, "startFrame": 0, "endFrame": 120,
        ]]])
        let clip = try #require(harness.editor.timeline.tracks.flatMap(\.clips).first)
        return (harness, clip)
    }

    @Test func gentlePushUsesClipRelativeScaleKeyframes() async throws {
        let (harness, clip) = try await fixture()
        let receipt = try await harness.runOK("apply_motion_preset", args: [
            "preset": "gentlePush", "clipIds": [clip.id],
        ]) as? [String: Any]
        #expect(receipt?["changed"] as? Bool == true)
        let track = try #require(harness.editor.clipFor(id: clip.id)?.scaleTrack)
        #expect(track.keyframes.map(\.frame) == [0, 119])
        #expect(track.keyframes.first?.value == AnimPair(a: 1, b: 1))
        #expect(track.keyframes.last?.value == AnimPair(a: 1.06, b: 1.06))
    }

    @Test func slideUpCombinesPositionAndOpacityInOneUndoStep() async throws {
        let (harness, clip) = try await fixture()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        _ = try await harness.runOK("apply_motion_preset", args: [
            "preset": "slideUp", "clipIds": [clip.id], "durationFrames": 12,
        ])
        let animated = try #require(harness.editor.clipFor(id: clip.id))
        #expect(animated.opacityTrack?.keyframes.map(\.frame) == [0, 12])
        #expect(animated.positionTrack?.keyframes.map(\.frame) == [0, 12])
        #expect(animated.positionTrack?.keyframes.first?.value.b == 0.05)
        #expect(undo.canUndo)
        undo.undo()
        #expect(harness.editor.clipFor(id: clip.id)?.opacityTrack == nil)
        #expect(harness.editor.clipFor(id: clip.id)?.positionTrack == nil)
    }

    @Test func existingAnimationRequiresExplicitOverwrite() async throws {
        let (harness, clip) = try await fixture()
        _ = try await harness.runOK("apply_motion_preset", args: [
            "preset": "fadeIn", "clipIds": [clip.id],
        ])
        let before = harness.editor.timeline
        let refused = await harness.runRaw("apply_motion_preset", args: [
            "preset": "slideUp", "clipIds": [clip.id],
        ])
        #expect(refused.isError)
        #expect(ToolHarness.textOf(refused).contains("overwrite=true"))
        #expect(harness.editor.timeline == before)

        let replaced = await harness.runRaw("apply_motion_preset", args: [
            "preset": "slideUp", "clipIds": [clip.id], "overwrite": true,
        ])
        #expect(!replaced.isError)
        #expect(harness.editor.clipFor(id: clip.id)?.positionTrack?.isActive == true)
    }

    @Test func discoveryPublishesStablePresetContract() {
        let tool = ToolDefinitions.all.first { $0.name == .applyMotionPreset }
        #expect(tool != nil)
        #expect(tool?.inputSchema["required"] as? [String] == ["preset", "clipIds"])
    }
}
