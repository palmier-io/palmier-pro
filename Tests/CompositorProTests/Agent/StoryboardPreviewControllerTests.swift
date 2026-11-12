import Foundation
import Testing
@testable import CompositorPro

@Suite("Storyboard preview lifecycle")
@MainActor
struct StoryboardPreviewControllerTests {
    @Test func editorSnapshotUsesSharedFittingWithoutAddingUndoOrApproval() async throws {
        let harness = editorFixture()
        let plan = try #require(harness.editor.editPlans.first)
        let before = harness.editor.timeline
        let snapshot = try await harness.editor.storyboardPreviewSnapshot(planId: plan.id)
        let asset = try #require(harness.editor.mediaAssets.first)
        #expect(snapshot.timeline.tracks[0].clips[0].transform == harness.editor.fitTransform(for: asset))
        #expect(harness.editor.timeline == before)
        #expect(harness.editor.editPlans == [plan])
        #expect(plan.productionRun == nil)
    }

    @Test func selectedMediaHydrationAndURLChangesInvalidateContext() throws {
        let harness = editorFixture()
        let plan = try #require(harness.editor.editPlans.first)
        let asset = try #require(harness.editor.mediaAssets.first)
        let initial = harness.editor.storyboardPreviewContext(planId: plan.id)
        asset.sourceWidth = 128
        let hydrated = harness.editor.storyboardPreviewContext(planId: plan.id)
        #expect(hydrated != initial)
        asset.url = URL(fileURLWithPath: "/preview-test/relinked.png")
        #expect(harness.editor.storyboardPreviewContext(planId: plan.id) != hydrated)
    }

    @Test func preparedMeasuredNarrationIsAvailableUntilGenerationRestarts() throws {
        let harness = editorFixture()
        let voice = harness.makeAsset(name: "Voice", type: .audio, duration: 3)
        var plan = try #require(harness.editor.editPlans.first)
        plan = EditPlan(id: plan.id, name: plan.name, timelineId: plan.timelineId, fps: plan.fps,
            width: plan.width, height: plan.height, shots: plan.shots,
            scriptBeats: PlanNarrationFixtures.beats(), narrationIntent: .init(startFrame: 0), narration: .init(mediaRef: voice.id))
        plan.narrationTiming = try PlanNarrationFixtures.timing(revision: #require(plan.narrationRevision))
        harness.editor.editPlans = [plan]
        #expect(!harness.editor.storyboardPreviewContext(planId: plan.id).unavailable.contains(voice.id))
        voice.generationStatus = .generating
        #expect(harness.editor.storyboardPreviewContext(planId: plan.id).unavailable.contains(voice.id))
    }

    @Test func identicalInFlightEditorRequestsShareOneRender() async throws {
        let harness = editorFixture()
        let plan = try #require(harness.editor.editPlans.first)
        let probe = PreviewLifecycleProbe(hold: true)
        let controller = controller(probe)
        let first = controller.prepare(editor: harness.editor, planId: plan.id)
        await probe.waitForStart()
        let second = controller.prepare(editor: harness.editor, planId: plan.id)
        #expect(await probe.started == 1)
        await probe.release()
        await first.value
        await second.value
        #expect(await probe.started == 1)
        #expect(controller.result != nil)
        await controller.invalidate().value
    }

    private func editorFixture() -> ToolHarness {
        let harness = ToolHarness(timeline: .init(name: "Editor", fps: 30, width: 64, height: 64))
        let asset = harness.makeAsset(name: "Still", type: .image, duration: 0)
        asset.sourceWidth = 64
        asset.sourceHeight = 32
        harness.editor.editPlans = [.init(id: "preview", name: "Preview", timelineId: harness.editor.activeTimelineId,
            fps: 30, width: 64, height: 64,
            shots: [.init(id: "scene", title: "Scene", startFrame: 0, endFrame: 30, mediaRef: asset.id)])]
        return harness
    }

    @Test func successfulPreviewOwnsOneTemporaryResultUntilDismissal() async throws {
        let snapshot = try await snapshot()
        let probe = PreviewLifecycleProbe()
        let controller = controller(probe)
        await controller.prepare(snapshot: { snapshot }, isCurrent: { true }).value
        #expect(!controller.isPreparing)
        #expect(controller.result?.key == snapshot.key)
        #expect(!controller.measured)
        #expect(await probe.removed.isEmpty)
        await controller.invalidate().value
        #expect(controller.result == nil)
        #expect(await probe.removed.count == 1)
    }

    @Test func cancellationAfterRenderBeginsDiscardsAndRemovesLateOutput() async throws {
        let snapshot = try await snapshot()
        let probe = PreviewLifecycleProbe(hold: true)
        let controller = controller(probe)
        let operation = controller.prepare(snapshot: { snapshot }, isCurrent: { true })
        await probe.waitForStart()
        let cleanup = controller.invalidate()
        await probe.release()
        await operation.value
        await cleanup.value
        #expect(controller.result == nil)
        #expect(controller.error == nil)
        #expect(await probe.removed.count == 1)
    }

    @Test func changedContextDiscardsOutputWithoutApprovingAnything() async throws {
        let snapshot = try await snapshot()
        let probe = PreviewLifecycleProbe(hold: true)
        let controller = controller(probe)
        final class Box: @unchecked Sendable { var current = true }
        let box = Box()
        let operation = controller.prepare(snapshot: { snapshot }, isCurrent: { box.current })
        await probe.waitForStart()
        box.current = false
        await probe.release()
        await operation.value
        #expect(controller.result == nil)
        #expect(controller.error != nil)
        #expect(await probe.removed.count == 1)
        #expect(snapshot.plan.productionRun == nil)
    }

    @Test func replacingPreviewWaitsForCanceledWorkBeforeNextRender() async throws {
        let snapshot = try await snapshot()
        let probe = PreviewLifecycleProbe(hold: true)
        let controller = controller(probe)
        let first = controller.prepare(snapshot: { snapshot }, isCurrent: { true })
        await probe.waitForStart()
        let second = controller.prepare(snapshot: { snapshot }, isCurrent: { true })
        #expect(await probe.started == 1)
        await probe.release()
        await first.value
        await probe.waitForStart()
        await probe.release()
        await second.value
        #expect(await probe.maximumActive == 1)
        #expect(await probe.removed.count == 1)
        #expect(controller.result != nil)
        await controller.invalidate().value
        #expect(await probe.removed.count == 2)
    }

    @Test func refusalDoesNotCreateAReadyPreview() async throws {
        let snapshot = try await snapshot()
        let controller = StoryboardPreviewController(render: { _ in throw StoryboardPreviewError.renderIncomplete },
            remove: { _ in }, makePlayer: { _ in nil })
        await controller.prepare(snapshot: { snapshot }, isCurrent: { true }).value
        #expect(controller.result == nil)
        #expect(!controller.isPreparing)
        #expect(controller.error != nil)
    }

    @Test func renderCleanupFailureRetainsLocalizedFailureAndNoReadyOutput() async throws {
        let snapshot = try await snapshot()
        let controller = StoryboardPreviewController(render: { _ in
            throw StoryboardPreviewService.CleanupFailure(operationError: StoryboardPreviewError.renderIncomplete,
                cleanupError: CocoaError(.fileWriteNoPermission))
        }, remove: { _ in }, makePlayer: { _ in nil })
        await controller.prepare(snapshot: { snapshot }, isCurrent: { true }).value
        let error = try #require(controller.error)
        #expect(error.contains(StoryboardPreviewError.renderIncomplete.userMessage))
        #expect(error.contains(CocoaError(.fileWriteNoPermission).localizedDescription))
        #expect(controller.result == nil)
        #expect(!controller.isPreparing)
    }

    private func controller(_ probe: PreviewLifecycleProbe) -> StoryboardPreviewController {
        StoryboardPreviewController(render: { try await probe.render($0) }, remove: { await probe.remove($0) },
            makePlayer: { _ in nil })
    }

    private func snapshot() async throws -> StoryboardPreviewSnapshot {
        let plan = EditPlan(id: "preview", name: "Preview", timelineId: "timeline", fps: 30, width: 32, height: 32,
            shots: [.init(id: "scene", title: "Scene", startFrame: 0, endFrame: 30, mediaRef: "still")])
        var manifest = MediaManifest()
        manifest.entries = [.init(id: "still", name: "Still", type: .image,
            source: .external(absolutePath: "/preview-test/still.png"), duration: 0)]
        return try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil)
    }
}

private actor PreviewLifecycleProbe {
    private let hold: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var started = 0
    private(set) var removed: [URL] = []

    init(hold: Bool = false) { self.hold = hold }

    func render(_ snapshot: StoryboardPreviewSnapshot) async throws -> StoryboardPreviewResult {
        active += 1
        maximumActive = max(maximumActive, active)
        started += 1
        if hold {
            await withCheckedContinuation {
                continuation = $0
                startWaiters.forEach { $0.resume() }
                startWaiters.removeAll()
            }
        }
        active -= 1
        return .init(url: URL(fileURLWithPath: "/preview-test/\(UUID().uuidString).mp4"), key: snapshot.key,
            frameCount: snapshot.frameCount, fps: snapshot.timeline.fps, width: 32, height: 32)
    }

    func remove(_ result: StoryboardPreviewResult) { removed.append(result.url) }
    func waitForStart() async {
        if continuation != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
