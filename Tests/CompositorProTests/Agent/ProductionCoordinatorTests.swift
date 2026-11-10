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

    // MARK: Export delivery

    private func coordinator(for plan: EditPlan) -> ProductionCoordinator {
        ProductionCoordinator(
            planId: plan.id,
            projectId: harness.editor.projectId ?? "test-project",
            timelineId: harness.editor.activeTimelineId,
            editor: harness.editor,
            packageCoordinator: ProjectPackageCoordinator(),
            exportQueue: harness.exportQueue,
            toolExecutor: harness.executor
        )
    }

    /// Text-only track added to the existing timeline: no visual mediaRef, so
    /// the uniqueness audit passes and rendering succeeds (black canvas with
    /// the title). Mutates in place so the plan's timeline identity survives.
    private func addTitleClip(text: String) {
        var clip = Fixtures.clip(mediaRef: "", mediaType: .text, start: 0, duration: 60)
        clip.textContent = text
        var timeline = harness.editor.timeline
        timeline.tracks = [Fixtures.videoTrack(clips: [clip])]
        harness.editor.timeline = timeline
    }

    private func seedRun(
        planId: String,
        phase: ProductionRun.Phase = .assembling,
        exportJobId: String? = nil
    ) -> ProductionRun {
        var run = ProductionRun(storyboardRevision: String(repeating: "a", count: 64))
        run.phase = phase
        run.comment = "Seeded"
        run.exportJobId = exportJobId
        // Past-approval phases require the revision to be approved.
        if phase != .awaitingStoryboardApproval && phase != .stale && phase != .canceled {
            run.approvedRevision = run.storyboardRevision
        }
        do {
            try harness.editor.commitProductionRun(
                run, plan: harness.editor.editPlan(id: planId)!, actionName: "Seed run")
        } catch {
            Issue.record("seedRun failed: \(error)")
        }
        return run
    }

    private func jobID(from result: ToolResult) throws -> String {
        let text = ToolHarness.textOf(result)
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return try #require(payload["jobId"] as? String)
    }

    /// A directory the export writer cannot open, so the job fails after
    /// submission with a deterministic write failure.
    nonisolated private static func makeUnwritableDirectory() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prod-unwritable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        return directory
    }

    nonisolated private static func removeDirectory(_ directory: URL) async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try FileManager.default.removeItem(at: directory)
    }

    @Test("Completed export persists a real verified terminal receipt")
    func completedExportPersistsVerifiedTerminalReceipt() async throws {
        let plan = createPlan()
        addTitleClip(text: "Verified delivery")
        let run = seedRun(planId: plan.id)
        let jobsBefore = harness.exportQueue.jobs.count
        let coordinator = coordinator(for: plan)
        try await coordinator.resumeProduction()

        let jobs = harness.exportQueue.jobs
        #expect(jobs.count == jobsBefore + 1, "resume submitted exactly one export job")
        guard let job = jobs.first else {
            Issue.record("no export job was created")
            return
        }
        let persistedRun = try #require(harness.editor.editPlan(id: plan.id)?.productionRun)
        guard let receipt = persistedRun.terminalReceipt else {
            Issue.record("terminal receipt was not persisted on the plan")
            return
        }
        #expect(receipt.deliveryVerified)
        #expect(receipt.phase == "completed")
        #expect(receipt.exportJobId == job.id.uuidString, "receipt must carry the real job id")
        #expect(receipt.exportPath == job.outputURL.path)
        #expect(receipt.approvedRevision == run.approvedRevision)
        #expect(receipt.completedAt != nil)
        #expect(persistedRun.phase == .completed)
        #expect(persistedRun.exportJobId == job.id.uuidString)
        let status = coordinator.status()
        #expect(status.phase == .completed)
        #expect(status.terminalReceipt?.deliveryVerified == true)
        #expect(status.exportJobId == job.id.uuidString)
    }

    @Test("Resume with a failed persisted export job records the receipt without resubmitting")
    func resumeWithFailedPersistedJobRecordsReceiptWithoutResubmitting() async throws {
        let plan = createPlan()
        addTitleClip(text: "Failed delivery")
        let destination = try await Self.makeUnwritableDirectory()
        defer { Task.detached { try? await Self.removeDirectory(destination) } }
        let queued = try await harness.executor.exportProject(
            harness.editor, ["mode": "video", "outputPath": destination.appendingPathComponent("failed.mp4").path, "overwrite": true])
        #expect(queued.isError != true)
        let failedJobID = try jobID(from: queued)
        let waited = try await harness.executor.manageExports(
            harness.editor, ["action": "wait", "jobId": failedJobID])
        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(ToolHarness.textOf(waited).utf8)) as? [String: Any])
        #expect(payload["status"] as? String == "failed", "\(ToolHarness.textOf(waited))")

        let jobsBefore = harness.exportQueue.jobs.count
        _ = seedRun(planId: plan.id, exportJobId: failedJobID)

        try await coordinator(for: plan).resumeProduction()

        #expect(harness.exportQueue.jobs.count == jobsBefore, "resume must not queue a second export")
        let persistedRun = try #require(harness.editor.editPlan(id: plan.id)?.productionRun)
        guard let receipt = persistedRun.terminalReceipt else {
            Issue.record("terminal receipt was not persisted on the plan")
            return
        }
        #expect(receipt.deliveryVerified == false)
        #expect(receipt.phase == "failed")
        #expect(receipt.exportJobId == failedJobID)
        #expect(receipt.errors.isEmpty == false)
        #expect(persistedRun.exportJobId == failedJobID)
    }

    @Test("Failed submission leaves the run unexported and without a receipt")
    func failedSubmissionPersistenceStaysClean() async throws {
        let plan = createPlan()
        let target = try #require(harness.editor.editPlan(id: plan.id))
        try harness.editor.commitProductionRun(ProductionRun(storyboardRevision: String(repeating: "b", count: 64)), plan: target, actionName: "Seed run")
        harness.editor.timeline = Fixtures.timeline()

        let submitted = try #require(harness.editor.editPlan(id: plan.id)?.productionRun)
        let coordinator = coordinator(for: plan)

        await #expect(throws: (any Error).self) {
            try await coordinator.resumeProduction()
        }
        let persisted = try #require(harness.editor.editPlan(id: plan.id)?.productionRun)
        #expect(persisted.exportJobId == nil)
        #expect(persisted.terminalReceipt == nil)
        #expect(persisted.exportPath == nil)
        #expect(persisted.storyboardRevision == submitted.storyboardRevision)
        #expect(harness.exportQueue.jobs.isEmpty)
    }
}