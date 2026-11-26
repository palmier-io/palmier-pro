import Foundation
import Testing
@testable import CompositorPro

@Suite("Production coordinator")
@MainActor
struct ProductionCoordinatorTests {
    private let harness = ToolHarness()

    private var coordinator: ProductionCoordinator { harness.editor.productionCoordinator }

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
        phase: ProductionRun.Phase = .approved,
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
            // An approved run implies an approved plan.
            _ = try harness.editor.changeEditPlanStatus(id: planId, to: .approved, actionName: "Approve plan")
        } catch {
            Issue.record("seedRun failed: \(error)")
        }
        return run
    }

    /// Marks the cut as already assembled so the run continues at review and delivery.
    private func markAssembled(planId: String) throws {
        let plan = try #require(harness.editor.editPlan(id: planId))
        var run = try #require(plan.productionRun)
        run.record(.init(kind: .assemble, state: .completed,
                         key: "assemble:" + (try ProductionRevision.assemblyInputs(plan))))
        try harness.editor.commitProductionRunMetadata(run, plan: plan)
    }

    @Test("Status reads the persisted run without touching the project")
    func statusReadsPersistedRun() async throws {
        let plan = createPlan(withStoryboard: true)
        let status = coordinator.status(planId: plan.id)
        #expect(status.phase == .awaitingStoryboardApproval)
        #expect(status.totalScenes == 1)
        #expect(status.runId == nil)
        #expect(status.terminalReceipt == nil)
    }

    @Test("Production requires an approved storyboard")
    func productionRequiresApproval() async throws {
        let plan = createPlan(withStoryboard: true)
        await #expect(throws: ProductionError.self) {
            try await coordinator.produce(planId: plan.id)
        }
        #expect(coordinator.status(planId: plan.id).phase == .awaitingStoryboardApproval)
    }

    @Test("Cancel production stops the run and prevents further edits")
    func cancelProductionStopsTheRun() async throws {
        let plan = createPlan(withStoryboard: true)
        _ = seedRun(planId: plan.id)
        try coordinator.cancel(planId: plan.id)
        #expect(coordinator.status(planId: plan.id).phase == .canceled)
        await #expect(throws: ProductionError.productionCanceled) {
            try await coordinator.resume(planId: plan.id)
        }
    }

    @Test("A run waiting for footage reports the dependency instead of editing")
    func blockedRunReportsItsDependency() async throws {
        var plan = createPlan()
        plan.shots[0].mediaRef = "not-yet-imported"
        try harness.editor.changeEditPlans(updates: [plan], actionName: "Add missing media ref")
        _ = seedRun(planId: plan.id)
        let before = harness.editor.timeline
        try await coordinator.resume(planId: plan.id)
        let status = coordinator.status(planId: plan.id)
        #expect(status.phase == .blocked)
        #expect(status.blockedReason?.contains("not-yet-imported") == true)
        #expect(harness.editor.timeline == before)
        #expect(harness.exportQueue.jobs.isEmpty)
    }

    @Test("Delivery is refused while error findings are open")
    func deliveryRefusedWhileErrorFindingsOpen() async throws {
        var plan = createPlan()
        plan.shots[0].mediaRef = "missing-media"
        try harness.editor.changeEditPlans(updates: [plan], actionName: "Add missing media ref")
        addTitleClip(text: "Missing source")
        _ = seedRun(planId: plan.id)
        try markAssembled(planId: plan.id)
        let jobsBefore = harness.exportQueue.jobs.count
        try await coordinator.resume(planId: plan.id)
        #expect(harness.exportQueue.jobs.count == jobsBefore, "refused delivery must not queue a job")
        let persistedRun = try #require(harness.editor.editPlan(id: plan.id)?.productionRun)
        #expect(persistedRun.reviewFindings.contains { $0.kind == "missingMedia" && $0.severity == .error })
        #expect(persistedRun.verifiedTimelineRevision == nil)
        let status = coordinator.status(planId: plan.id)
        #expect(status.reviewFindings.count == persistedRun.reviewFindings.count)
        #expect(status.verifiedTimelineRevision == nil)
        #expect(status.phase == .blocked)
        #expect(status.blockedReason?.contains("Delivery refused") == true)
    }

    @Test func recordedReviewErrorsSurviveStructuralChecksAndBlockDelivery() async throws {
        let plan = createPlan()
        addTitleClip(text: "Needs review")
        let run = seedRun(planId: plan.id)
        try markAssembled(planId: plan.id)
        let finding = ProductionRun.Finding(
            shotId: "scene1", timelineRevision: run.storyboardRevision, severity: .error,
            kind: "wrongSubject", message: "Selected footage does not show the requested subject.")
        try harness.editor.recordProductionReview(planId: plan.id, findings: [finding])
        try await coordinator.resume(planId: plan.id)
        let persisted = try #require(harness.editor.editPlan(id: plan.id)?.productionRun)
        #expect(persisted.reviewFindings.contains(finding))
        #expect(persisted.terminalReceipt == nil)
        #expect(harness.exportQueue.jobs.isEmpty)
        #expect(persisted.blockedReason?.contains("wrongSubject") == true)
    }

    @Test func emptyOutputTimelineCannotPassStructuralReview() async throws {
        let plan = createPlan()
        _ = seedRun(planId: plan.id)
        try markAssembled(planId: plan.id)
        try await coordinator.resume(planId: plan.id)
        let run = try #require(harness.editor.editPlan(id: plan.id)?.productionRun)
        #expect(run.reviewFindings.contains { $0.kind == "emptyTimeline" && $0.severity == .error })
        #expect(run.verifiedTimelineRevision == nil)
        #expect(harness.exportQueue.jobs.isEmpty)
    }

    @Test func aMissingExportJobBlocksInsteadOfDeliveringTwice() async throws {
        let plan = createPlan()
        addTitleClip(text: "Missing job")
        _ = seedRun(planId: plan.id, exportJobId: UUID().uuidString)
        try markAssembled(planId: plan.id)
        let jobsBefore = harness.exportQueue.jobs.count
        try await coordinator.resume(planId: plan.id)
        #expect(harness.exportQueue.jobs.count == jobsBefore)
        let run = try #require(harness.editor.editPlan(id: plan.id)?.productionRun)
        #expect(run.blockedReason?.contains("no longer available") == true)
        #expect(run.terminalReceipt == nil)
    }

    @Test func deliveryIsCertifiedAgainstTheExportedFile() async throws {
        let plan = createPlan()
        addTitleClip(text: "Certified delivery")
        _ = seedRun(planId: plan.id)
        try markAssembled(planId: plan.id)
        try await coordinator.resume(planId: plan.id)
        let run = try #require(harness.editor.editPlan(id: plan.id)?.productionRun)
        let receipt = try #require(run.terminalReceipt)
        #expect(receipt.deliveryVerified)
        #expect(receipt.verifiedTimelineRevision == receipt.exportedTimelineRevision)
        #expect(receipt.verifiedTimelineRevision == run.verifiedTimelineRevision)
        let path = try #require(receipt.exportPath)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(run.phase == .completed)
        // The delivered file is the reviewed revision, not a different cut.
        #expect(run.exportedTimelineRevision == run.verifiedTimelineRevision)
        for job in harness.exportQueue.jobs { await TimelineRenderer.removeTemporaryRender(job.outputURL) }
    }
}
