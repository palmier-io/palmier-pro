import Foundation

extension EditorViewModel {
    func storyboardReport(
        planId: String,
        resolve: @Sendable (EditPlan, MediaManifest, Set<String>) async throws -> StoryboardReport = {
            try await StoryboardResolver.resolve(plan: $0, manifest: $1, unavailable: $2)
        }
    ) async throws -> StoryboardReport {
        guard let plan = editPlan(id: planId), plan.timelineId == activeTimelineId,
              plan.fps == timeline.fps, plan.width == timeline.width, plan.height == timeline.height else {
            throw EditPlanValidationError.invalidReference("Storyboard requires its matching active timeline.")
        }
        let revision = visualReviewRevision
        let manifest = mediaManifest
        let unavailable = storyboardUnavailableMediaRefs(for: plan)
        let report = try await resolve(plan, manifest, unavailable)
        try Task.checkCancellation()
        guard editPlan(id: planId) == plan, visualReviewRevision == revision,
              storyboardUnavailableMediaRefs(for: plan) == unavailable else {
            throw EditPlanValidationError.invalidReference("Storyboard, media, project, or timeline changed during review; read the current revision.")
        }
        return report
    }

    @discardableResult
    func prepareStoryboard(planId: String) async throws -> StoryboardReport {
        let report = try await storyboardReport(planId: planId)
        guard let plan = editPlan(id: planId), plan.status == .proposed || plan.status == .approved else {
            throw EditPlanValidationError.invalidReference("Prepare a storyboard for a proposed or approved plan.")
        }
        if let run = plan.productionRun, run.storyboardRevision == report.revision, run.phase != .stale, run.phase != .canceled {
            return report
        }
        var run = plan.productionRun ?? ProductionRun(storyboardRevision: report.revision)
        run.phase = .awaitingStoryboardApproval
        run.storyboardRevision = report.revision
        run.approvedRevision = nil
        run.visualReviews = run.visualReviews.filter { review in
            report.cards.contains { $0.shot.id == review.sceneId && $0.selectionRevision == review.selectionRevision }
        }
        try commitProductionRun(run, plan: plan, actionName: L10n.string("Prepare Storyboard"))
        var prepared = report
        prepared.phase = .awaitingStoryboardApproval
        return prepared
    }

    func reviewStoryboardScene(planId: String, revision: String, review: ProductionRun.VisualReview) async throws -> StoryboardReport {
        let report = try await verifiedStoryboardReport(planId: planId)
        guard var plan = editPlan(id: planId), var run = plan.productionRun,
              report.revision == revision, run.storyboardRevision == revision,
              run.phase == .awaitingStoryboardApproval,
              let card = report.cards.first(where: { $0.shot.id == review.sceneId }),
              card.selectionRevision == review.selectionRevision,
              card.mediaType == .image || card.mediaType == .video else {
            throw EditPlanValidationError.invalidReference("Scene inspection requires a prepared current storyboard and its exact selected image/video revision.")
        }
        let expected: ProductionRun.VisualReview.Coverage = card.mediaType == .image ? .fullStill : .fullSpan
        guard review.coverage == expected else {
            throw EditPlanValidationError.invalidReference("Inspect the full still or continuously play the entire selected video span; sampled frames are insufficient.")
        }
        run.visualReviews.removeAll { $0.sceneId == review.sceneId }
        run.visualReviews.append(review)
        run.visualReviews.sort { $0.sceneId < $1.sceneId }
        try run.validate()
        plan.productionRun = run
        let before = editPlan(id: planId)
        let snapshotRevision = visualReviewRevision
        let unavailable = storyboardUnavailableMediaRefs(for: plan)
        let reviewed = try await StoryboardResolver.resolve(plan: plan, manifest: mediaManifest, unavailable: unavailable)
        try Task.checkCancellation()
        guard editPlan(id: planId) == before, visualReviewRevision == snapshotRevision,
              storyboardUnavailableMediaRefs(for: plan) == unavailable else {
            throw EditPlanValidationError.invalidReference("Storyboard changed during inspection; review the current selection.")
        }
        try changeEditPlans(updates: [plan], actionName: L10n.string("Review Storyboard Scene"), updatingProductionRun: true)
        return reviewed
    }

    func approveStoryboard(planId: String, revision: String, comment: String) async throws -> StoryboardReport {
        let report = try await verifiedStoryboardReport(planId: planId)
        guard let plan = editPlan(id: planId), var run = plan.productionRun,
              plan.status == .proposed || plan.status == .approved,
              report.revision == revision, run.storyboardRevision == revision,
              run.phase == .awaitingStoryboardApproval || run.phase == .approved,
              report.blockers.isEmpty else {
            throw EditPlanValidationError.invalidReference("Storyboard approval requires the current prepared revision without blockers: \(report.blockers.joined(separator: ", ")).")
        }
        let comment = try EditPlan.validatedText(comment, field: "storyboard comment")
        run.phase = .approved
        run.approvedRevision = revision
        run.comment = comment
        try run.validate()
        if run != plan.productionRun || plan.status != .approved {
            try undo.perform(L10n.string("Approve Storyboard")) {
                try commitProductionRun(run, plan: plan, actionName: L10n.string("Approve Storyboard"))
                _ = try changeEditPlanStatus(id: planId, to: .approved, actionName: L10n.string("Approve Storyboard"))
            }
        }
        var approved = report
        approved.phase = .approved
        return approved
    }

    func cancelProductionReview(planId: String) throws {
        try Task.checkCancellation()
        guard let plan = editPlan(id: planId), var run = plan.productionRun else {
            throw EditPlanValidationError.invalidReference("No production run exists for this plan.")
        }
        run.phase = .canceled
        run.approvedRevision = nil
        try commitProductionRun(run, plan: plan, actionName: L10n.string("Cancel Production"))
    }

    func verifiedStoryboardReport(planId: String) async throws -> StoryboardReport {
        let report = try await storyboardReport(planId: planId)
        let plan = editPlan(id: planId)
        let revision = visualReviewRevision
        let unavailable = plan.map(storyboardUnavailableMediaRefs) ?? []
        var seen = Set<String>()
        var sources: [(String, MediaAsset, URL, MediaInputIdentity)] = []
        for card in report.cards {
            try Task.checkCancellation()
            guard let ref = card.shot.mediaRef, seen.insert(ref).inserted else { continue }
            guard let asset = mediaAssetsById[ref], let identity = asset.inputIdentity, identity.isValid else {
                throw EditPlanValidationError.invalidReference("Selected source '\(ref)' needs a measured input identity before inspection or production.")
            }
            let url = asset.url
            sources.append((ref, asset, url, identity))
            let measured = try await MediaInputIdentityService.shared.identify(url)
            try Task.checkCancellation()
            guard editPlan(id: planId) == plan, visualReviewRevision == revision,
                  mediaAssetsById[ref] === asset, asset.url == url, asset.inputIdentity == identity,
                  measured == identity, card.inputId == measured.inputId else {
                throw EditPlanValidationError.invalidReference("Selected source changed; prepare and inspect the current storyboard before production.")
            }
        }
        guard plan.map(storyboardUnavailableMediaRefs) == unavailable, sources.allSatisfy({ ref, asset, url, identity in
            mediaAssetsById[ref] === asset && asset.url == url && asset.inputIdentity == identity
        }) else {
            throw EditPlanValidationError.invalidReference("Selected sources changed during inspection; review the current storyboard.")
        }
        return report
    }

    private func storyboardUnavailableMediaRefs(for plan: EditPlan) -> Set<String> {
        Set(plan.shots.compactMap { shot in
            guard let ref = shot.mediaRef else { return nil }
            return missingMediaRefs.contains(ref) || unprocessableMediaRefs.contains(ref)
                || (mediaAssetsById[ref].map { $0.generationStatus != .none } ?? true) ? ref : nil
        })
    }

    private func commitProductionRun(_ run: ProductionRun, plan: EditPlan, actionName: String) throws {
        var next = plan
        next.productionRun = run
        try changeEditPlans(updates: [next], actionName: actionName, updatingProductionRun: true)
    }
}
