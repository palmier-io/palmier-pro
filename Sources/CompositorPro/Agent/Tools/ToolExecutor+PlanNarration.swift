import Foundation

extension ToolExecutor {
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

    func verifyPlanNarration(_ editor: EditorViewModel, plan: EditPlan) async throws {
        guard plan.scriptBeats != nil else { return }
        let session = try PlanNarrationSession(editor: editor, planId: plan.id)
        try await editor.verifyPlanNarrationAttachment(session: session)
        guard let timing = plan.narrationTiming, timing.unresolvedBeatIds.isEmpty else {
            throw ToolError("Narration alignment is unresolved. Use plan_edit action=measure_narration before assembly.")
        }
        try timing.validated(beats: plan.scriptBeats ?? [], revision: plan.narrationRevision)
        let fingerprint = try await NarrationTimingService.fingerprint(session.sourceURL)
        try Task.checkCancellation()
        guard self.editor === editor else { throw ToolError("Project binding changed during narration verification.") }
        try session.validateCurrent(in: editor)
        guard fingerprint == timing.sourceFingerprint else {
            throw ToolError("Narration file changed since measurement. Measure the current source before assembly.")
        }
    }
}
