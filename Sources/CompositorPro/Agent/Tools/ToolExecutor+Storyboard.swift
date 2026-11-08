import Foundation

extension ToolExecutor {
    static let storyboardActions: Set<String> = ["prepare_storyboard", "read_storyboard", "review_storyboard_scene", "approve_storyboard", "cancel_production"]

    private struct StoryboardInput: DecodableToolArgs {
        let action: String
        let planId: String
        let storyboardRevision: String?
        let sceneId: String?
        let selectionRevision: String?
        let coverage: ProductionRun.VisualReview.Coverage?
        let reviewer: String?
        let evidence: String?
        let facesRevealed: Bool?
        let rightsConfirmed: Bool?
        let suspectedDuplicate: Bool?
        let comment: String?
        static let allowedKeys: Set<String> = ["action", "planId", "storyboardRevision", "sceneId", "selectionRevision",
            "coverage", "reviewer", "evidence", "facesRevealed", "rightsConfirmed", "suspectedDuplicate", "comment"]
    }

    func storyboardEdit(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let action = args["action"] as? String ?? ""
        var allowed: Set<String> = ["action", "planId"]
        switch action {
        case "approve_storyboard": allowed.formUnion(["storyboardRevision", "comment"])
        case "review_storyboard_scene": allowed = StoryboardInput.allowedKeys.subtracting(["comment"])
        default: break
        }
        try validateUnknownKeys(args, allowed: allowed, path: "plan_edit \(action)")
        let input: StoryboardInput = try decodeToolArgs(args, path: "plan_edit \(action)")
        let before = editor.editPlan(id: input.planId)
        let report: StoryboardReport
        switch action {
        case "prepare_storyboard": report = try await editor.prepareStoryboard(planId: input.planId)
        case "read_storyboard": report = try await editor.storyboardReport(planId: input.planId)
        case "approve_storyboard":
            guard let revision = input.storyboardRevision else { throw ToolError("Approval requires the exact reviewed storyboardRevision.") }
            report = try await editor.approveStoryboard(planId: input.planId, revision: revision, comment: input.comment ?? "")
        case "review_storyboard_scene":
            guard let revision = input.storyboardRevision, let sceneId = input.sceneId,
                  let selection = input.selectionRevision, let coverage = input.coverage,
                  let reviewer = input.reviewer, let evidence = input.evidence,
                  let faces = input.facesRevealed, let rights = input.rightsConfirmed,
                  let suspected = input.suspectedDuplicate else {
                throw ToolError("Scene review requires storyboardRevision, sceneId, selectionRevision, coverage, reviewer, evidence, facesRevealed, rightsConfirmed, and suspectedDuplicate.")
            }
            report = try await editor.reviewStoryboardScene(planId: input.planId, revision: revision,
                review: .init(sceneId: sceneId, selectionRevision: selection, coverage: coverage,
                              reviewer: reviewer, evidence: evidence, facesRevealed: faces,
                              rightsConfirmed: rights, suspectedDuplicate: suspected))
        case "cancel_production":
            var canceled = try await editor.storyboardReport(planId: input.planId)
            try editor.cancelProductionReview(planId: input.planId)
            canceled.phase = .canceled
            report = canceled
        default: throw ToolError("Unknown storyboard action.")
        }
        let noOp = before == editor.editPlan(id: input.planId)
        return try await Self.storyboardResult(report, noOp: noOp)
    }

    @concurrent
    private static func storyboardResult(_ report: StoryboardReport, noOp: Bool) async throws -> ToolResult {
        guard let json = jsonString(report.receipt.merging(["noOp": noOp], uniquingKeysWith: { _, new in new })) else {
            throw ToolError("Could not encode storyboard receipt.")
        }
        return .ok(json)
    }
}
