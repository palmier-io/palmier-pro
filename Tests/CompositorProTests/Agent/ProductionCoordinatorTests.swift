import Foundation
import Testing
@testable import CompositorPro

@Suite("Production coordinator")
@MainActor
struct ProductionCoordinatorTests {
    private var harness: ToolHarness!

    init() async {
        harness = ToolHarness()
    }

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
            projectId: harness.editor.projectId,
            timelineId: harness.editor.activeTimelineId,
            editor: harness.editor,
            packageCoordinator: harness.editor.projectPackageCoordinator,
            exportQueue: harness.exportQueue,
            toolExecutor: harness.executor
        )

        try await coordinator.startProduction()

        let status = coordinator.status()
        #expect(!status.runId.isEmpty)
        #expect(status.projectId == harness.editor.projectId)
        #expect(status.timelineId == harness.editor.activeTimelineId)
        #expect(status.totalScenes == 1)
        #expect(status.phase == .awaitingStoryboardApproval)
    }

    @Test("Resume production restores state")
    func resumeProductionRestoresState() async throws {
        let plan = createPlan(withStoryboard: true)
        let coordinator = ProductionCoordinator(
            planId: plan.id,
            projectId: harness.editor.projectId,
            timelineId: harness.editor.activeTimelineId,
            editor: harness.editor,
            packageCoordinator: harness.editor.projectPackageCoordinator,
            exportQueue: harness.exportQueue,
            toolExecutor: harness.executor
        )

        try await coordinator.startProduction()
        try await coordinator.resumeProduction()

        let status = coordinator.status()
        #expect(status.phase == .awaitingStoryboardApproval)
    }

    @Test("Cancel production stops and clears state")
    func cancelProductionStopsAndClears() async throws {
        let plan = createPlan(withStoryboard: true)
        let coordinator = ProductionCoordinator(
            planId: plan.id,
            projectId: harness.editor.projectId,
            timelineId: harness.editor.activeTimelineId,
            editor: harness.editor,
            packageCoordinator: harness.editor.projectPackageCoordinator,
            exportQueue: harness.exportQueue,
            toolExecutor: harness.executor
        )

        try await coordinator.startProduction()
        try await coordinator.cancelProduction()

        let status = coordinator.status()
        #expect(status.phase == .canceled)

        await #expect(throws: ProductionError.self) {
            try await coordinator.resumeProduction()
        }
    }

    @Test("Production status is inspectable")
    func statusIsInspectable() async throws {
        let plan = createPlan(withStoryboard: true)
        let coordinator = ProductionCoordinator(
            planId: plan.id,
            projectId: harness.editor.projectId,
            timelineId: harness.editor.activeTimelineId,
            editor: harness.editor,
            packageCoordinator: harness.editor.projectPackageCoordinator,
            exportQueue: harness.exportQueue,
            toolExecutor: harness.executor
        )

        let initialStatus = coordinator.status()
        #expect(!initialStatus.runId.isEmpty)
        #expect(initialStatus.phase == .awaitingStoryboardApproval)
        #expect(initialStatus.totalScenes == 1)
    }
}

