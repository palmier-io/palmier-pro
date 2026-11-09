import Foundation
import Testing
@testable import CompositorPro

private actor StoryboardPreparationGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Never>?

    func hold() async {
        await withCheckedContinuation { continuation in
            completion = continuation
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish() {
        completion?.resume()
        completion = nil
    }
}

@Suite("Storyboard lifecycle")
@MainActor
struct StoryboardLifecycleTests {
    @Test(arguments: ["cancel", "timeline", "manifest", "project", "script"])
    func canceledOrStalePreparationCannotReturnCurrentReview(change: String) async throws {
        let harness = ToolHarness()
        let plan = EditPlan(name: "Lifecycle", timelineId: harness.editor.activeTimelineId,
                            fps: harness.editor.timeline.fps, width: harness.editor.timeline.width, height: harness.editor.timeline.height)
        try harness.editor.changeEditPlans(creates: [plan], actionName: "Create")
        let gate = StoryboardPreparationGate()
        let task = Task {
            try await harness.editor.storyboardReport(planId: plan.id) { plan, manifest, unavailable in
                await gate.hold()
                return try await StoryboardResolver.resolve(plan: plan, manifest: manifest, unavailable: unavailable)
            }
        }
        await gate.waitUntilStarted()
        switch change {
        case "cancel": task.cancel()
        case "timeline": harness.editor.timeline.width += 1
        case "manifest": harness.editor.mediaManifest.folders.append(.init(name: "New folder"))
        case "project": harness.editor.projectURL = URL(fileURLWithPath: "/isolated/changed.compositorpro")
        default:
            var current = try #require(harness.editor.editPlan(id: plan.id))
            current.goal = "Changed editorial intent"
            try harness.editor.changeEditPlans(updates: [current], actionName: "Revise")
        }
        let expected = harness.editor.editPlans
        await gate.finish()
        do { _ = try await task.value; Issue.record("Stale or canceled preparation returned a current board.") }
        catch { #expect(change != "cancel" || error is CancellationError) }
        #expect(harness.editor.editPlans == expected)
        #expect(harness.editor.editPlan(id: plan.id)?.productionRun == nil)
    }

    @Test func malformedSavedApprovalIsRejected() async throws {
        var plan = EditPlan(name: "Invalid review", timelineId: "timeline", fps: 30, width: 1920, height: 1080)
        plan.productionRun = ProductionRun(phase: .approved, storyboardRevision: String(repeating: "a", count: 64), approvedRevision: nil)
        await #expect(throws: EditPlanValidationError.self) { try await Self.decode(plan) }
    }

    @Test(arguments: ["cancel", "cancel-run", "timeline", "manifest", "project", "script"])
    func changedContextCannotCommitPreparedSceneRevision(change: String) async throws {
        let harness = ToolHarness()
        let plan = EditPlan(name: "Revision", timelineId: harness.editor.activeTimelineId,
            fps: harness.editor.timeline.fps, width: harness.editor.timeline.width, height: harness.editor.timeline.height,
            shots: [.init(id: "scene", title: "Scene", startFrame: 0, endFrame: 60,
                          narrationLink: .init(firstBeatId: "beat", lastBeatId: "beat"))],
            scriptBeats: [.init(beatId: "beat", text: "Original narration.", purpose: "Explain")])
        try harness.editor.changeEditPlans(creates: [plan], actionName: "Create")
        let board = try await harness.editor.prepareStoryboard(planId: plan.id)
        let gate = StoryboardPreparationGate()
        let task = Task {
            try await harness.editor.reviseStoryboardScene(planId: plan.id, revision: board.revision, sceneId: "scene",
                beatEdits: [.init(beatId: "beat", text: "Prepared replacement.")], visual: nil) { plan, manifest, unavailable in
                await gate.hold()
                return try await StoryboardResolver.resolve(plan: plan, manifest: manifest, unavailable: unavailable)
            }
        }
        await gate.waitUntilStarted()
        switch change {
        case "cancel": task.cancel()
        case "cancel-run": try harness.editor.cancelProductionReview(planId: plan.id)
        case "timeline": harness.editor.timeline.width += 1
        case "manifest": harness.editor.mediaManifest.folders.append(.init(name: "Changed media"))
        case "project": harness.editor.projectURL = URL(fileURLWithPath: "/isolated/changed.compositorpro")
        default:
            var current = try #require(harness.editor.editPlan(id: plan.id))
            current.scriptBeats?[0].text = "Concurrent user edit."
            try harness.editor.changeEditPlans(updates: [current], actionName: "User edit")
        }
        let expected = harness.editor.editPlans
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        await gate.finish()
        do { _ = try await task.value; Issue.record("Stale or canceled revision committed.") }
        catch { #expect(change != "cancel" || error is CancellationError) }
        #expect(harness.editor.editPlans == expected)
        #expect(!undo.canUndo)
    }

    @concurrent private static func decode(_ plan: EditPlan) async throws {
        _ = try EditPlanStore.decode(EditPlanStore.encode([plan]))
    }
}
