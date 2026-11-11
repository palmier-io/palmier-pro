import Foundation
import Testing
@testable import CompositorPro

@Suite("Production continuation")
@MainActor
struct ProductionContinuationTests {
    @Test func aRunWaitingForFootageContinuesWhenTheMediaArrives() async throws {
        let directory = try await PlanAssemblyFixtures.makeDirectory()
        defer { Task.detached { try? await AudioFinishingFixtures.remove(directory) } }
        let editor = EditorViewModel()
        editor.exportQueue = ExportQueue()
        // The shot's footage is still importing.
        let arriving = PlanAssemblyFixtures.addSource(to: editor, directory: directory, id: "arriving")
        arriving.generationStatus = .downloading
        let plan = EditPlan(
            name: "Continued production",
            timelineId: editor.activeTimelineId,
            fps: editor.timeline.fps, width: editor.timeline.width, height: editor.timeline.height,
            shots: [EditPlanShot(id: "shot", title: "Shot", startFrame: 0, endFrame: 60, mediaRef: "arriving")])
        try editor.changeEditPlans(creates: [plan], actionName: "Create")
        _ = try editor.changeEditPlanStatus(id: plan.id, to: .approved, actionName: "Approve")
        var run = ProductionRun(storyboardRevision: String(repeating: "a", count: 64))
        run.phase = .approved
        run.approvedRevision = run.storyboardRevision
        try editor.commitProductionRun(run, plan: try #require(editor.editPlan(id: plan.id)), actionName: "Seed run")

        let status = try await editor.productionCoordinator.resume(planId: plan.id)
        #expect(status.phase == .blocked)
        #expect(status.blockedReason?.contains("arriving") == true)
        #expect(status.steps.contains { $0.kind == .assemble && $0.state == .pending })
        #expect(editor.timeline.tracks.flatMap(\.clips).isEmpty)

        // The import finishes; the run continues on the media event and re-evaluates
        // the step instead of waiting for media that is no longer missing.
        let finalized = await editor.finalizeImportedAsset(arriving)
        #expect(finalized)
        await editor.productionCoordinator.awaitPendingResumes()
        let resumed = editor.productionStatus(planId: plan.id)
        #expect(resumed.blockedReason?.hasPrefix("Waiting for media") != true)
        #expect(resumed.steps.contains { $0.kind == .assemble && $0.state != .pending })
    }

    @Test func aCanceledRunNeverEditsTheTimelineAgain() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        defer { Task.detached { try? await AudioFinishingFixtures.remove(directory) } }
        let editor = EditorViewModel()
        editor.exportQueue = ExportQueue()
        editor.mediaAssets.append(PlanAssemblyFixtures.addSource(to: editor, directory: directory))
        let plan = try PlanAssemblyFixtures.plan(in: editor)
        var run = ProductionRun(storyboardRevision: String(repeating: "a", count: 64))
        run.phase = .approved
        run.approvedRevision = run.storyboardRevision
        try editor.commitProductionRun(run, plan: try #require(editor.editPlan(id: plan.id)), actionName: "Seed run")
        try editor.productionCoordinator.cancel(planId: plan.id)
        let before = editor.timeline
        await #expect(throws: ProductionError.productionCanceled) {
            try await editor.productionCoordinator.resume(planId: plan.id)
        }
        #expect(editor.timeline == before)
        #expect(editor.productionStatus(planId: plan.id).phase == .canceled)
    }
}
