import Foundation

extension ToolExecutor {
    static let storyboardActions: Set<String> = [
        "prepare_storyboard", "read_storyboard", "review_storyboard_scene",
        "approve_storyboard", "cancel_production", "revise_storyboard_scene",
        "reorder_storyboard", "import_storyboard_markdown", "export_storyboard_markdown",
    ]

    private struct StoryboardInput: DecodableToolArgs {
        let action: String
        let planId: String?
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
        let beatEdits: [StoryboardBeatEdit]?
        let visual: StoryboardVisualEdit?
        let sceneIds: [String]?
        let markdown: String?
        let name: String?
        static let allowedKeys: Set<String> = [
            "action", "planId", "storyboardRevision", "sceneId", "selectionRevision",
            "coverage", "reviewer", "evidence", "facesRevealed", "rightsConfirmed",
            "suspectedDuplicate", "comment", "beatEdits", "visual", "sceneIds",
            "markdown", "name",
        ]
    }

    func storyboardEdit(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let action = args["action"] as? String ?? ""
        var allowed: Set<String> = ["action"]
        switch action {
        case "import_storyboard_markdown":
            allowed.formUnion(["planId", "markdown", "name"])
        case "export_storyboard_markdown":
            allowed.formUnion(["planId"])
        case "approve_storyboard":
            allowed.formUnion(["planId", "storyboardRevision", "comment"])
        case "review_storyboard_scene":
            allowed.formUnion(["planId", "storyboardRevision", "sceneId", "selectionRevision", "coverage", "reviewer", "evidence", "facesRevealed", "rightsConfirmed", "suspectedDuplicate"])
        case "revise_storyboard_scene":
            allowed.formUnion(["planId", "storyboardRevision", "sceneId", "beatEdits", "visual"])
        case "reorder_storyboard":
            allowed.formUnion(["planId", "storyboardRevision", "sceneIds"])
        default:
            allowed.formUnion(["planId"])
        }
        try validateUnknownKeys(args, allowed: allowed, path: "plan_edit \(action)")
        if let edits = args["beatEdits"] as? [Any] {
            for (index, raw) in edits.enumerated() {
                guard let object = raw as? [String: Any] else { throw ToolError("beatEdits[\(index)] must be an object.") }
                try validateUnknownKeys(object, allowed: ["beatId", "text", "spokenText"], path: "beatEdits[\(index)]")
            }
        }
        if let object = args["visual"] as? [String: Any] {
            try validateUnknownKeys(object, allowed: ["mediaRef", "license", "attribution", "sourceStartSeconds", "sourceEndSeconds"], path: "visual")
        }
        let input: StoryboardInput = try decodeToolArgs(args, path: "plan_edit \(action)")

        if action == "export_storyboard_markdown" {
            guard let planId = input.planId, let plan = editor.editPlan(id: planId) else {
                throw ToolError("Unknown planId '\(input.planId ?? "")'.")
            }
            let md = StoryboardMarkdownCodec.export(plan: plan)
            guard let json = Self.jsonString([
                "status": "ok",
                "planId": plan.id,
                "name": plan.name,
                "markdown": md,
            ]) else {
                throw ToolError("Could not encode export receipt.")
            }
            return .ok(json)
        }

        if action == "import_storyboard_markdown" {
            guard let markdown = input.markdown, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError("import_storyboard_markdown requires non-empty 'markdown'.")
            }
            let timeline = editor.timeline
            var plan = try StoryboardMarkdownCodec.parse(
                markdown: markdown,
                timelineId: timeline.id,
                fps: timeline.fps,
                width: timeline.width,
                height: timeline.height,
                fallbackName: input.name ?? "Imported Storyboard"
            )
            if let name = input.name, !name.isEmpty {
                plan.name = name
            }
            if let existingId = input.planId, editor.editPlan(id: existingId) != nil {
                plan.id = existingId
                _ = try editor.changeEditPlans(updates: [plan], actionName: "Update Storyboard (Agent)")
            } else {
                _ = try editor.changeEditPlans(creates: [plan], actionName: "Import Storyboard (Agent)")
            }
            guard let stored = editor.editPlan(id: plan.id) else {
                throw ToolError("Could not retrieve stored imported plan.")
            }
            guard let json = Self.jsonString([
                "status": "ok",
                "plan": stored.receipt(includeDetails: true),
            ]) else {
                throw ToolError("Could not encode import receipt.")
            }
            return .ok(json)
        }

        guard let planId = input.planId else {
            throw ToolError("planId is required for \(action).")
        }
        let before = editor.editPlan(id: planId)
        let report: StoryboardReport
        switch action {
        case "prepare_storyboard": report = try await editor.prepareStoryboard(planId: planId)
        case "read_storyboard": report = try await editor.storyboardReport(planId: planId)
        case "revise_storyboard_scene":
            guard let revision = input.storyboardRevision, let sceneId = input.sceneId else {
                throw ToolError("Scene revision requires storyboardRevision and sceneId.")
            }
            report = try await editor.reviseStoryboardScene(planId: planId, revision: revision, sceneId: sceneId,
                beatEdits: input.beatEdits ?? [], visual: input.visual)
        case "reorder_storyboard":
            guard let revision = input.storyboardRevision, let sceneIds = input.sceneIds else {
                throw ToolError("Reordering requires storyboardRevision and every current sceneId in the requested order.")
            }
            report = try await editor.reorderStoryboard(planId: planId, revision: revision, sceneIds: sceneIds)
        case "approve_storyboard":
            guard let revision = input.storyboardRevision else { throw ToolError("Approval requires the exact reviewed storyboardRevision.") }
            report = try await editor.approveStoryboard(planId: planId, revision: revision, comment: input.comment ?? "")
        case "review_storyboard_scene":
            guard let revision = input.storyboardRevision, let sceneId = input.sceneId,
                  let selection = input.selectionRevision, let coverage = input.coverage,
                  let reviewer = input.reviewer, let evidence = input.evidence,
                  let faces = input.facesRevealed, let rights = input.rightsConfirmed,
                  let suspected = input.suspectedDuplicate else {
                throw ToolError("Scene review requires storyboardRevision, sceneId, selectionRevision, coverage, reviewer, evidence, facesRevealed, rightsConfirmed, and suspectedDuplicate.")
            }
            report = try await editor.reviewStoryboardScene(planId: planId, revision: revision,
                review: .init(sceneId: sceneId, selectionRevision: selection, coverage: coverage,
                              reviewer: reviewer, evidence: evidence, facesRevealed: faces,
                              rightsConfirmed: rights, suspectedDuplicate: suspected))
        case "cancel_production":
            var canceled = try await editor.storyboardReport(planId: planId)
            try editor.cancelProductionReview(planId: planId)
            canceled.phase = .canceled
            report = canceled
        default: throw ToolError("Unknown storyboard action.")
        }
        let noOp = before == editor.editPlan(id: planId)
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
