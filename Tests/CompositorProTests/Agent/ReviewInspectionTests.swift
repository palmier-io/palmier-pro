import Foundation
import Testing
@testable import CompositorPro

@Suite("Review inspections")
@MainActor
struct ReviewInspectionTests {
    private func makeHarness() -> (ToolHarness, String) {
        let harness = ToolHarness()
        var plan = EditPlan(name: "Plan", timelineId: harness.editor.timeline.id, fps: 30, width: 1920, height: 1080)
        plan = (try? EditPlan.validatedNew(plan, timelineId: plan.timelineId, fps: 30, width: 1920, height: 1080, existingCount: 0)) ?? plan
        harness.editor.editPlans = [plan]
        return (harness, harness.editor.editPlans[0].id)
    }

    @Test func inspectionsAreRecordedDeduplicatedAndBounded() throws {
        let (harness, planId) = makeHarness()
        var checkpoints = 0
        harness.editor.onProjectCheckpointRequired = { checkpoints += 1 }

        let first = ReviewInspection(startFrame: 0, endFrame: 90, outputRevision: "rev-1",
                                     sampledFrames: [0, 45, 89], qualityWarnings: [])
        #expect(harness.editor.recordReviewInspection(planId: planId, inspection: first))
        #expect(checkpoints == 1)
        #expect(harness.editor.editPlan(id: planId)?.reviewInspections.count == 1)

        // Same range and revision replaces the older evidence instead of stacking duplicates.
        let repeated = ReviewInspection(startFrame: 0, endFrame: 90, outputRevision: "rev-1",
                                        sampledFrames: [1, 2], qualityWarnings: ["audioClipping"])
        #expect(harness.editor.recordReviewInspection(planId: planId, inspection: repeated))
        let stored = try #require(harness.editor.editPlan(id: planId))
        #expect(stored.reviewInspections.count == 1)
        #expect(stored.reviewInspections.first?.qualityWarnings == ["audioClipping"])

        for index in 0..<(ReviewInspection.maximumRetained + 5) {
            let inspection = ReviewInspection(startFrame: index, endFrame: index + 10,
                                              outputRevision: "rev-\(index)", sampledFrames: [], qualityWarnings: [])
            harness.editor.recordReviewInspection(planId: planId, inspection: inspection)
        }
        let bounded = try #require(harness.editor.editPlan(id: planId))
        #expect(bounded.reviewInspections.count == ReviewInspection.maximumRetained)
        #expect(bounded.reviewInspections.first?.outputRevision == "rev-\(ReviewInspection.maximumRetained + 4)")
    }

    @Test func unknownPlanIsRefused() {
        let (harness, _) = makeHarness()
        let inspection = ReviewInspection(startFrame: 0, endFrame: 10, outputRevision: "rev",
                                          sampledFrames: [], qualityWarnings: [])
        #expect(harness.editor.recordReviewInspection(planId: "missing", inspection: inspection) == false)
    }

    @Test func receiptExposesInspectionCountAndRows() throws {
        let (harness, planId) = makeHarness()
        harness.editor.recordReviewInspection(
            planId: planId,
            inspection: ReviewInspection(startFrame: 0, endFrame: 30, outputRevision: "rev-1",
                                         sampledFrames: [0, 15, 29], qualityWarnings: ["musicMaskingNarration"])
        )
        let plan = try #require(harness.editor.editPlan(id: planId))
        let receipt = plan.receipt(includeDetails: true)
        #expect(receipt["inspectionCount"] as? Int == 1)
        let inspections = try #require(receipt["inspections"] as? [[String: Any]])
        #expect(inspections.first?["outputRevision"] as? String == "rev-1")
        #expect(inspections.first?["endFrame"] as? Int == 30)
    }
}
