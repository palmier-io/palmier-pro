import Foundation

extension EditorViewModel {
    func reviseStoryboardScene(planId: String, revision: String, sceneId: String,
                               beatEdits: [StoryboardBeatEdit], visual: StoryboardVisualEdit?,
                               resolve: @Sendable (EditPlan, MediaManifest, Set<String>) async throws -> StoryboardReport = {
                                   try await StoryboardResolver.resolve(plan: $0, manifest: $1, unavailable: $2)
                               }) async throws -> StoryboardReport {
        try await editStoryboard(planId: planId, revision: revision, actionName: L10n.string("Revise Storyboard Scene"), resolve: resolve) { plan in
            if let visual {
                guard let asset = self.mediaAssetsById[visual.mediaRef], asset.type == .image || asset.type == .video else {
                    throw EditPlanValidationError.invalidReference("Replacement visual must name an exact current library image/video mediaRef.")
                }
            }
            return try StoryboardEditing.revise(plan: plan, sceneId: sceneId, beatEdits: beatEdits, visual: visual)
        }
    }

    func reorderStoryboard(planId: String, revision: String, sceneIds: [String]) async throws -> StoryboardReport {
        try await editStoryboard(planId: planId, revision: revision, actionName: L10n.string("Reorder Storyboard"), resolve: {
            try await StoryboardResolver.resolve(plan: $0, manifest: $1, unavailable: $2)
        }) { plan in
            try StoryboardEditing.reorder(plan: plan, sceneIds: sceneIds)
        }
    }

    private func editStoryboard(planId: String, revision: String, actionName: String,
                                 resolve: @Sendable (EditPlan, MediaManifest, Set<String>) async throws -> StoryboardReport,
                                 edit: (EditPlan) throws -> EditPlan) async throws -> StoryboardReport {
        let before = try await storyboardReport(planId: planId)
        guard let plan = editPlan(id: planId), plan.productionRun != nil,
              plan.status == .proposed || plan.status == .approved,
              before.phase != .canceled, before.revision == revision else {
            throw EditPlanValidationError.invalidReference("Revise an active draft storyboard using its current revision; applied plans require a section revision.")
        }
        var next = try edit(plan)
        guard next != plan else { return before }
        if next.scriptBeats != plan.scriptBeats { next.narrationTiming = nil }
        if !next.hasSameStoryboardIntent(as: plan) {
            next.productionRun?.phase = .stale
            next.productionRun?.approvedRevision = nil
        }
        try next.validateArtifacts()
        let snapshot = visualReviewRevision
        let unavailable = storyboardUnavailableMediaRefs(for: next)
        let result = try await resolve(next, mediaManifest, unavailable)
        try Task.checkCancellation()
        guard editPlan(id: planId) == plan, visualReviewRevision == snapshot,
              storyboardUnavailableMediaRefs(for: next) == unavailable else {
            throw EditPlanValidationError.invalidReference("Storyboard changed during revision; retry against current state.")
        }
        guard result.uniqueness.conflicts.isEmpty else {
            throw EditPlanValidationError.invalidReference("Revision repeats a visual source; choose unique coverage before changing the storyboard.")
        }
        next.productionRun = plan.productionRun
        try changeEditPlans(updates: [next], actionName: actionName)
        return result
    }
}
