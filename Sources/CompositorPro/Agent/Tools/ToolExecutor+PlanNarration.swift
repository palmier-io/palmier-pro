import Foundation

extension ToolExecutor {
    func prepareApprovedPlanNarration(_ editor: EditorViewModel, planId: String) async throws -> ToolResult {
        let result = try await editor.prepareApprovedNarration(planId: planId, render: narrationRender, transcribe: narrationTranscribe)
        guard let plan = editor.editPlan(id: planId) else { throw ToolError("Unknown planId '\(planId)'.") }
        var receipt = plan.receipt(includeDetails: true)
        switch result {
        case .noOp:
            receipt["noOp"] = true
        case .prepared:
            receipt["prepared"] = true
        case .unresolved(_, let reason):
            receipt["prepared"] = true
            receipt["unresolved"] = true
            receipt["blocker"] = reason
        }
        return .ok(Self.jsonString(receipt) ?? "{}")
    }

    func measurePlanNarration(_ editor: EditorViewModel, planId: String) async throws -> ToolResult {
        let session = try PlanNarrationSession(editor: editor, planId: planId)
        try await editor.verifyPlanNarrationAttachment(session: session)
        guard self.editor === editor else { throw ToolError("Project binding changed during narration verification.") }
        guard let source = session.plan.narration, let beats = session.plan.scriptBeats,
              let revision = session.plan.narrationRevision else {
            throw ToolError("Narration measurement requires scriptBeats and a narration source.")
        }
        let timing = try await narrationTimingService.measure(url: session.sourceURL, source: source,
                                                                language: session.plan.narrationIntent?.language, beats: beats,
                                                               revision: revision, previous: session.plan.narrationTiming)
        try await editor.verifyPlanNarrationAttachment(session: session)
        try Task.checkCancellation()
        guard self.editor === editor else { throw ToolError("Project binding changed during narration measurement.") }
        let receipt = try editor.commitPlanNarrationTiming(timing, session: session)
        guard let plan = editor.editPlan(id: planId) else { throw ToolError("Plan disappeared during narration measurement.") }
        return .ok(Self.jsonString(plan.receipt(includeDetails: true).merging(
            ["noOp": receipt.updated.isEmpty, "aligned": timing.unresolvedBeatIds.isEmpty],
            uniquingKeysWith: { _, new in new }
        )) ?? "{}")
    }

}
