import Foundation

extension EditorViewModel {
    struct PreparedPlanAssembly {
        let id: String
        let revision: VisualReviewRevision
        let preparation: PlanAssembly.Preparation
    }

    struct PlanAssemblyReceipt {
        let plan: EditPlan
        let preparationId: String
        let resolved: PlanAssembly.Resolved
        let changed: Bool
        let timelineChanged: Bool

        var receipt: [String: Any] {
            plan.receipt(includeDetails: true).merging(resolved.receipt, uniquingKeysWith: { _, new in new })
                .merging(["preparationId": preparationId, "ready": true, "applied": resolved.complete,
                          "changed": changed, "noOp": !changed, "timelineChanged": timelineChanged],
                         uniquingKeysWith: { _, new in new })
        }
    }

    typealias PlanAssemblyPreparing = @Sendable (PlanAssembly.Input) async throws -> PlanAssembly.Preparation

    func preparePlanAssembly(
        planId: String, request: PlanAssembly.Request = .init(),
        prepare: @escaping PlanAssemblyPreparing = { try await PlanAssembly.prepare($0) }
    ) async throws -> PreparedPlanAssembly {
        try Task.checkCancellation()
        guard !editPlansLoadFailed, !projectPackageCoordinator.isClosing,
              let plan = editPlan(id: planId), plan.timelineId == activeTimelineId else {
            throw EditPlanValidationError.invalidReference("Plan assembly requires its open, readable, active timeline.")
        }
        guard plan.status == .approved || plan.status == .ready || plan.status == .applied else {
            throw EditPlanValidationError.invalidReference("Only an approved or ready plan can be applied. Approve the current plan first.")
        }
        let revision = visualReviewRevision
        let timelines = timelines
        let timeline = timeline
        var approvalBlockers: [String] = []
        if plan.productionRun != nil {
            let board = try await verifiedStoryboardReport(planId: plan.id)
            try validatePlanAssemblySnapshot(plan: plan, revision: revision)
            approvalBlockers = board.blockers
            if !board.canProduce { approvalBlockers.append("Explicit approval of the current storyboard is required before production.") }
        }
        let refs = try await PlanAssembly.requiredMediaRefs(plan: plan, timelines: timelines)
        try validatePlanAssemblySnapshot(plan: plan, revision: revision)
        var sources: [String: PlanAssembly.Source] = [:]
        for ref in refs {
            guard let asset = mediaAssetsById[ref] else { continue }
            sources[ref] = planAssemblySource(asset)
        }
        let input = PlanAssembly.Input(plan: plan, timeline: timeline, timelines: timelines, sources: sources,
                                       request: request, approvalBlockers: approvalBlockers)
        let result = try await prepare(input)
        try validatePlanAssemblySnapshot(plan: plan, revision: revision, sources: sources)
        let prepared = PreparedPlanAssembly(id: UUID().uuidString, revision: revision, preparation: result)
        preparedPlanAssembly = result.resolved == nil ? nil : prepared
        return prepared
    }

    func commitPlanAssembly(_ prepared: PreparedPlanAssembly) async throws -> PlanAssemblyReceipt {
        let input = prepared.preparation.input
        guard let result = prepared.preparation.resolved, prepared.preparation.blockers.isEmpty else {
            throw EditPlanValidationError.invalidReference("Plan '\(input.plan.id)' is not ready: \(prepared.preparation.blockers.joined(separator: " "))")
        }
        return try await projectPackageCoordinator.withIntent { _ in
            try validatePlanAssemblySnapshot(plan: input.plan, revision: prepared.revision, sources: input.sources)
            try await PlanAssembly.verifySources(prepared.preparation)
            try validatePlanAssemblySnapshot(plan: input.plan, revision: prepared.revision, sources: input.sources)
            return try await projectPackageCoordinator.withMutation { _ in
                try validatePlanAssemblySnapshot(plan: input.plan, revision: prepared.revision, sources: input.sources)
                var nextPlan = input.plan
                nextPlan.assembly = result.state
                nextPlan.status = result.complete ? .applied : .approved
                let timelineChanged = result.timelineChanged
                let changed = timelineChanged || nextPlan != input.plan
                guard changed else {
                    return PlanAssemblyReceipt(plan: input.plan, preparationId: prepared.id, resolved: result,
                                               changed: false, timelineChanged: false)
                }
                nextPlan.updatedAt = Date()
                try nextPlan.validateArtifacts()
                guard let index = editPlans.firstIndex(where: { $0.id == input.plan.id }) else {
                    throw EditPlanValidationError.invalidReference("Plan was removed before assembly.")
                }
                let before = PlanAssemblyUndoState(timeline: input.timeline, plan: input.plan,
                    selectedClipIds: selectedClipIds, selectedGap: selectedGap)
                let after = PlanAssemblyUndoState(timeline: result.timeline, plan: nextPlan,
                    selectedClipIds: selectedClipIds.intersection(result.remainingClipIds), selectedGap: timelineChanged ? nil : selectedGap)
                undo.perform(L10n.string("Apply Plan")) {
                    if timelineChanged { timeline = result.timeline }
                    editPlans[index] = nextPlan
                    selectedClipIds = after.selectedClipIds
                    selectedGap = after.selectedGap
                    registerPlanAssemblySwap(before: before, after: after)
                }
                preparedPlanAssembly = nil
                if timelineChanged { notifyTimelineChanged() }
                onProjectCheckpointRequired?()
                return PlanAssemblyReceipt(plan: nextPlan, preparationId: prepared.id, resolved: result,
                                           changed: true, timelineChanged: timelineChanged)
            }
        }
    }

    func preparedAssembly(id: String, planId: String, request: PlanAssembly.Request) throws -> PreparedPlanAssembly {
        guard let prepared = preparedPlanAssembly, prepared.id == id,
              prepared.preparation.input.plan.id == planId, prepared.preparation.input.request == request else {
            throw EditPlanValidationError.invalidReference("Preparation is unavailable or belongs to another request; prepare this plan again.")
        }
        try validatePlanAssemblySnapshot(plan: prepared.preparation.input.plan, revision: prepared.revision,
                                         sources: prepared.preparation.input.sources)
        return prepared
    }

    private func planAssemblySource(_ asset: MediaAsset) -> PlanAssembly.Source {
        let blocker: String?
        if missingMediaRefs.contains(asset.id) || unprocessableMediaRefs.contains(asset.id) {
            blocker = "missing or unreadable media; relink or import_media."
        } else if case .failed = asset.generationStatus {
            blocker = "failed media; retry its original import or generation."
        } else if asset.generationStatus != .none {
            blocker = "media is still \(asset.generationStatus.serialized); wait for its terminal result."
        } else { blocker = nil }
        return .init(placement: .init(asset: asset), url: asset.url, expectedIdentity: asset.inputIdentity, blocker: blocker)
    }

    private func validatePlanAssemblySnapshot(
        plan: EditPlan, revision: VisualReviewRevision, sources: [String: PlanAssembly.Source] = [:]
    ) throws {
        try Task.checkCancellation()
        guard !projectPackageCoordinator.isClosing, editPlan(id: plan.id) == plan,
              visualReviewRevision == revision, sources.allSatisfy({ ref, source in
                  mediaAssetsById[ref].map { planAssemblySource($0) == source } ?? false
              }) else {
            throw EditPlanValidationError.invalidReference("Plan, source, project, settings, or timeline changed during preparation; retry current state.")
        }
    }

    private struct PlanAssemblyUndoState {
        let timeline: Timeline
        let plan: EditPlan
        let selectedClipIds: Set<String>
        let selectedGap: GapSelection?
    }

    private func registerPlanAssemblySwap(before: PlanAssemblyUndoState, after: PlanAssemblyUndoState) {
        undo.register(L10n.string("Apply Plan"), withTarget: self) { editor in
            guard let index = editor.editPlans.firstIndex(where: { $0.id == before.plan.id }),
                  editor.timeline(for: before.timeline.id) != nil else { return }
            editor.timeline = before.timeline
            editor.editPlans[index] = before.plan
            editor.selectedClipIds = before.selectedClipIds
            editor.selectedGap = before.selectedGap
            editor.preparedPlanAssembly = nil
            editor.notifyTimelineChanged()
            editor.onProjectCheckpointRequired?()
            editor.registerPlanAssemblySwap(before: after, after: before)
        }
    }
}
