import Foundation
import Testing
@testable import CompositorPro

@Suite("Plan brief artifacts")
struct PlanBriefTests {
    private func briefPlan() -> EditPlan {
        EditPlan(
            id: "plan-brief",
            name: "Peninsula explainer",
            goal: "Explain the corridor.",
            timelineId: "timeline-brief",
            fps: 30,
            width: 1920,
            height: 1080,
            sections: [EditPlanSection(
                id: "section-brief", title: "Hook", summary: "Opening.",
                startFrame: 0, endFrame: 90)],
            shots: [EditPlanShot(
                id: "shot-brief", title: "Harbor at dusk",
                startFrame: 0, endFrame: 90,
                requirement: ShotRequirement(
                    narrativePurpose: "Establish the location before the claim.",
                    subject: "Container harbor", action: "Cranes loading",
                    location: "Penang", shotSize: .wide, motion: .static_,
                    sourceTypes: [.stockVideo], exclusions: ["no generated imagery"],
                    targetDurationSeconds: 3, handleSeconds: 1))],
            brief: PlanBrief(
                audience: "Regional policymakers",
                durationSeconds: 3,
                aspectFormat: "16:9",
                tone: "documentary",
                language: "en",
                realism: .realFootageOnly,
                deliveryConstraints: "-16 LUFS dialogue-forward mix",
                inferredChoices: ["hook_verified": "kept the harbor shot first"]),
            soundCues: [PlanSoundCue(
                cueId: "cue-ambience", role: .ambience, purpose: "Harbor room tone under the whole open.",
                anchorFrame: 0, durationSeconds: 3, notes: nil)]
        )
    }

    @Test func artifactValidationAcceptsABriefWithCuesAndRequirements() throws {
        var plan = briefPlan()
        try plan.validateArtifacts()
        try EditPlan.ensureUniqueIDs(plan)
    }

    @Test func briefFailsValidationWithControlCharacters() {
        #expect(throws: EditPlanValidationError.self) {
            try PlanBrief(audience: "policy\u{7}makers").validated()
        }
    }

    @Test func soundCueCannotAnchorToBothBeatAndFrame() {
        #expect(throws: EditPlanValidationError.self) {
            try PlanSoundCue(cueId: "cue-x", role: .sfx, purpose: "Impact.",
                             anchorBeatId: "beat-1", anchorFrame: 0).validated()
        }
    }

    @Test func negativeHandleSecondsFailValidation() {
        #expect(throws: EditPlanValidationError.self) {
            try ShotRequirement(narrativePurpose: "Establish.", handleSeconds: -1).validated()
        }
    }

    @Test func cueAnchoredToUnknownBeatIsRefused() throws {
        var plan = briefPlan()
        plan.scriptBeats = nil
        plan.soundCues = [PlanSoundCue(
            cueId: "cue-beat", role: .sfx, purpose: "Whoosh.", anchorBeatId: "missing-beat")]
        #expect(throws: EditPlanValidationError.self) {
            try plan.validateArtifacts()
        }
    }

    @Test func duplicateCueIdIsRefused() throws {
        var plan = briefPlan()
        plan.soundCues = (plan.soundCues ?? []) + [
            PlanSoundCue(cueId: "cue-ambience", role: .music, purpose: "Duplicate id should refuse."),
        ]
        try plan.validateArtifacts()
        #expect(throws: EditPlanValidationError.self) {
            try EditPlan.ensureUniqueIDs(plan)
        }
    }

    @Test func durationMatchComparesShotSpanWithRequest() throws {
        let plan = briefPlan()
        let match = try #require(plan.durationMatchReceipt)
        #expect(match["requestedSeconds"] as? Double == 3)
        #expect(match["planSeconds"] as? Double == 3)
        #expect(match["withinTolerance"] as? Bool == true)
        #expect(match["deltaSeconds"] as? Double != nil)
    }

    @Test func briefAndCuesSurviveThePersistenceRoundTrip() async throws {
        let plan = briefPlan()
        let roundTripped = try await Task.detached {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("plan-brief-roundtrip-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try EditPlanStore.writePackageFile(try EditPlanStore.encode([plan]), to: directory, sourceURL: nil)
            return try EditPlanStore.readPackageFile(at: directory)
        }.value
        let decoded = try #require(roundTripped.plans.first)
        #expect(decoded.brief == plan.brief)
        #expect(decoded.soundCues == plan.soundCues)
        #expect(decoded.shots.first?.requirement == plan.shots.first?.requirement)
    }

    @Test func receiptsExposeBriefCuesAndRequirements() throws {
        var plan = briefPlan()
        try plan.validateArtifacts()
        let receipt = plan.receipt(includeDetails: true)
        let receiptJSON = try #require(ToolExecutor.jsonString(receipt))
        #expect(receiptJSON.contains("\"brief\""))
        #expect(receiptJSON.contains("\"soundCues\""))
        #expect(receiptJSON.contains("\"requirement\""))
        #expect(receiptJSON.contains("durationMatch"))
    }
}
