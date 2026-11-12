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

    @Test func shotRejectionsSurviveValidationReceiptsAndRoundTrip() throws {
        var plan = briefPlan()
        plan.shots[0].rejections = [ShotRejection(
            candidateRef: "asset-rejected", reason: .wrongAction,
            evidence: "Container cranes were visible but no loading motion.")]
        try plan.validateArtifacts()
        try EditPlan.ensureUniqueIDs(plan)
        let receiptJSON = try #require(ToolExecutor.jsonString(plan.receipt(includeDetails: true)))
        #expect(receiptJSON.contains("\"rejections\""))
        #expect(receiptJSON.contains("asset-rejected"))
        #expect(receiptJSON.contains("wrong_action"))
        #expect(receiptJSON.contains("Container cranes"))

        let decoded = try #require(EditPlanStore.decode(EditPlanStore.encode([plan])).first)
        #expect(decoded.shots == plan.shots)
        let shot = decoded.shots.first
        #expect(shot?.rejections.first?.candidateRef == "asset-rejected")
        #expect(shot?.rejections.first?.evidence == "Container cranes were visible but no loading motion.")
    }

    @Test func shotRejectionRequiresInspectionEvidence() throws {
        #expect(throws: EditPlanValidationError.self) {
            try ShotRejection(candidateRef: "asset-x", reason: .wrongSubject, evidence: "   ").validated()
        }
    }

    @Test func duplicateShotRejectionCandidatesAreRefused() throws {
        var plan = briefPlan()
        plan.shots[0].rejections = [
            ShotRejection(candidateRef: "asset-x", reason: .wrongSubject, evidence: "Subject mismatch."),
            ShotRejection(candidateRef: "asset-x", reason: .wrongAction, evidence: "Action mismatch."),
        ]
        #expect(throws: EditPlanValidationError.self) {
            try plan.validateArtifacts()
        }
    }

    @Test func shotRejectionsRespectTheAdvertisedLimit() throws {
        var plan = briefPlan()
        plan.shots[0].rejections = (0..<33).map {
            ShotRejection(candidateRef: "asset-\($0)", reason: .wrongSubject, evidence: "Subject mismatch.")
        }
        #expect(throws: EditPlanValidationError.self) {
            try plan.validateArtifacts()
        }
    }

    @Test func briefChangesInvalidateStoryboardApproval() {
        let revision = String(repeating: "a", count: 64)
        var before = briefPlan()
        before.productionRun = ProductionRun(phase: .approved, storyboardRevision: revision, approvedRevision: revision)
        var after = before
        after.brief?.realism = .illustrative
        after.invalidateStoryboardApproval(comparedTo: before)
        #expect(after.productionRun?.phase == .stale)
        #expect(after.productionRun?.approvedRevision == nil)
    }

    @Test func durationMatchUsesShotsWithoutSections() throws {
        var plan = briefPlan()
        plan.sections = []
        let match = try #require(plan.durationMatchReceipt)
        #expect(match["planSeconds"] as? Double == 3)
    }

    @Test func durationMatchUsesShotTimingInsteadOfSectionEstimates() throws {
        var plan = briefPlan()
        plan.sections[0].endFrame = 900
        let match = try #require(plan.durationMatchReceipt)
        #expect(match["planSeconds"] as? Double == 3)
    }

    @Test func soundCueChangesInvalidateStoryboardApproval() {
        let revision = String(repeating: "a", count: 64)
        var before = briefPlan()
        before.productionRun = ProductionRun(phase: .approved, storyboardRevision: revision, approvedRevision: revision)
        var after = before
        after.soundCues?[0].purpose = "Keep the opening quiet."
        after.invalidateStoryboardApproval(comparedTo: before)
        #expect(after.productionRun?.phase == .stale)
        #expect(after.productionRun?.approvedRevision == nil)
    }

    @Test(arguments: [-1, maxFrameArg, Int.max])
    func invalidCueFramesAreRefusedWithoutOverflow(frame: Int) {
        #expect(throws: EditPlanValidationError.self) {
            try PlanSoundCue(cueId: "invalid-frame", role: .sfx, purpose: "Impact.", anchorFrame: frame).validated()
        }
    }

    @Test func sourceTypeNormalizationPreservesOrder() throws {
        let requirement = ShotRequirement(narrativePurpose: "Establish.", sourceTypes: [.stockVideo, .library, .stockImage, .stockVideo])
        let normalized = try requirement.validated()
        #expect(normalized.sourceTypes == [.stockVideo, .library, .stockImage])
        #expect(try normalized.validated() == normalized)
    }

    @Test func sectionRoleRoundTripsAndAppearsInReceipt() throws {
        for role in SectionRole.allCases {
            let section = EditPlanSection(
                id: "section-\(role.rawValue)",
                title: "Section \(role.rawValue)",
                summary: "Summary",
                startFrame: 0,
                endFrame: 90,
                role: role
            )
            let encoded = try JSONEncoder().encode(section)
            let decoded = try JSONDecoder().decode(EditPlanSection.self, from: encoded)
            #expect(decoded.role == role)
        }
        var plan = briefPlan()
        plan.sections[0].role = .hook
        let receipt = plan.receipt(includeDetails: true)
        let sections = try #require(receipt["sections"] as? [[String: Any]])
        #expect(sections.first?["role"] as? String == "hook")
    }

    @Test func soundCueMediaRefAndTrackIdRoundTrip() throws {
        let cue = PlanSoundCue(
            cueId: "cue-voice",
            role: .voice,
            purpose: "Voiceover narration",
            anchorFrame: 10,
            durationSeconds: 2.5,
            notes: "Clear and loud",
            mediaRef: "asset-voice",
            trackId: "track-voice"
        )
        let validated = try cue.validated()
        #expect(validated.mediaRef == "asset-voice")
        #expect(validated.trackId == "track-voice")

        let encoded = try JSONEncoder().encode(cue)
        let decoded = try JSONDecoder().decode(PlanSoundCue.self, from: encoded)
        #expect(decoded.mediaRef == "asset-voice")
        #expect(decoded.trackId == "track-voice")

        let receipt = cue.receipt
        #expect(receipt["mediaRef"] as? String == "asset-voice")
        #expect(receipt["trackId"] as? String == "track-voice")
    }
}
