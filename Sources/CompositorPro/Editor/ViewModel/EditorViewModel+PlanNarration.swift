import Foundation

struct PlanNarrationSession {
    var plan: EditPlan
    var timeline: Timeline
    var projectURL: URL?
    var sourceURL: URL

    @MainActor
    init(editor: EditorViewModel, planId: String) throws {
        guard let plan = editor.editPlan(id: planId), let source = plan.narration,
              let asset = editor.mediaAssetsById[source.mediaRef], asset.type == .audio,
              asset.generationStatus == .none,
              !editor.missingMediaRefs.contains(asset.id), !editor.unprocessableMediaRefs.contains(asset.id),
              plan.timelineId == editor.activeTimelineId,
              plan.fps == editor.timeline.fps, plan.width == editor.timeline.width, plan.height == editor.timeline.height else {
            throw EditPlanValidationError.invalidReference("Narration timing requires the plan's matching active timeline and a ready audio asset.")
        }
        self.plan = plan
        timeline = editor.timeline
        projectURL = editor.projectURL
        sourceURL = asset.url
    }

    @MainActor
    func validateCurrent(in editor: EditorViewModel) throws {
        guard editor.projectURL == projectURL, editor.timeline == timeline,
              editor.editPlan(id: plan.id) == plan, editor.activeTimelineId == plan.timelineId,
              let asset = editor.mediaAssetsById[plan.narration?.mediaRef ?? ""], asset.url == sourceURL,
              asset.generationStatus == .none,
              !editor.missingMediaRefs.contains(asset.id), !editor.unprocessableMediaRefs.contains(asset.id) else {
            throw EditPlanValidationError.invalidReference("Plan, narration, project, or timeline changed during timing preparation; retry the current revision.")
        }
    }
}

extension EditorViewModel {
    func commitPlanNarrationTiming(_ timing: NarrationTiming, session: PlanNarrationSession) throws -> EditPlanChangeReceipt {
        try Task.checkCancellation()
        try session.validateCurrent(in: self)
        var plan = session.plan
        try timing.validated(beats: plan.scriptBeats ?? [], revision: plan.narrationRevision)
        plan.narrationTiming = timing
        return try changeEditPlans(updates: [plan], actionName: L10n.string("Measure Narration"))
    }
}
