import Foundation
import Testing
@testable import CompositorPro

@Suite("Production coordinator")
@MainActor
struct ProductionCoordinatorTests {
    private let harness = ToolHarness()

    private func createPlan(withStoryboard: Bool = false) -> EditPlan {
        var plan = EditPlan(
            name: "Test Production",
            timelineId: harness.editor.activeTimelineId,
            fps: harness.editor.timeline.fps,
            width: harness.editor.timeline.width,
            height: harness.editor.timeline.height,
            shots: [
                EditPlanShot(
                    id: "scene1",
                    title: "Scene 1",
                    startFrame: 0,
                    endFrame: 60,
                    narrationLink: SceneNarrationLink(firstBeatId: "beat1", lastBeatId: "beat1")
                )
            ],
            scriptBeats: [
                ScriptBeat(beatId: "beat1", text: "Test narration.", purpose: "Explain")
            ]
        )
        if withStoryboard {
            plan.narrationIntent = NarrationIntent(language: "en", startFrame: 0)
        }
        try? harness.editor.changeEditPlans(creates: [plan], actionName: "Create")
        return harness.editor.editPlan(id: plan.id)!
    }

    @Test("Start production creates production run")
    func startProductionCreatesRun() async throws {
        let plan = createPlan(withStoryboard: true)
        let coordinator = ProductionCoordinator(
            planId: plan.id,
            projectId: harness.editor.projectId ?? "test-project",
            timelineId: harness.editor.activeTimelineId,
            editor: harness.editor,
            packageCoordinator: ProjectPackageCoordinator(),
            exportQueue: harness.exportQueue,
            toolExecutor: harness.executor
        )

        try await coordinator.startProduction()

        let status = coordinator.status()
        #expect(status.runId == coordinator.runId.uuidString)
        #expect(status.projectId == (harness.editor.projectId ?? "test-project"))
        #expect(status.timelineId == harness.editor.activeTimelineId)
        #expect(status.totalScenes == 1)
    }

    @Test("Cancel production stops and clears state")
    func cancelProductionStopsAndClears() async throws {
        let plan = createPlan(withStoryboard: true)
        let coordinator = ProductionCoordinator(
            planId: plan.id,
            projectId: harness.editor.projectId ?? "test-project",
            timelineId: harness.editor.activeTimelineId,
            editor: harness.editor,
            packageCoordinator: ProjectPackageCoordinator(),
            exportQueue: harness.exportQueue,
            toolExecutor: harness.executor
        )

        try await coordinator.startProduction()
        try await coordinator.cancelProduction()

        let status = coordinator.status()
        #expect(status.phase == ProductionRun.Phase.canceled)
    }

    @Test("Production status is inspectable")
    func statusIsInspectable() async throws {
        let plan = createPlan(withStoryboard: true)
        let coordinator = ProductionCoordinator(
            planId: plan.id,
            projectId: harness.editor.projectId ?? "test-project",
            timelineId: harness.editor.activeTimelineId,
            editor: harness.editor,
            packageCoordinator: ProjectPackageCoordinator(),
            exportQueue: harness.exportQueue,
            toolExecutor: harness.executor
        )

        try await coordinator.startProduction()

        let status = coordinator.status()
        #expect(status.runId == coordinator.runId.uuidString)
        #expect(status.totalScenes == 1)
    }

    @Test("Resume from canceled state remains canceled")
    func resumeFromCanceledRemainsCanceled() async throws {
        let plan = createPlan(withStoryboard: true)
        let coordinator = ProductionCoordinator(
            planId: plan.id,
            projectId: harness.editor.projectId ?? "test-project",
            timelineId: harness.editor.activeTimelineId,
            editor: harness.editor,
            packageCoordinator: ProjectPackageCoordinator(),
            exportQueue: harness.exportQueue,
            toolExecutor: harness.executor
        )

        try await coordinator.startProduction()
        try await coordinator.cancelProduction()

        // Resume should throw because phase is canceled
        await #expect(throws: ProductionError.productionCanceled) {
            try await coordinator.resumeProduction()
        }
    }
}