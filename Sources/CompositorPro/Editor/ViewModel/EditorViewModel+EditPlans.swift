import Foundation

struct EditPlanChangeReceipt {
    var created: [EditPlan] = []
    var updated: [EditPlan] = []
    var deletedIds: [String] = []
}

extension EditorViewModel {
    func editPlan(id: String) -> EditPlan? {
        editPlans.first { $0.id == id }
    }

    @discardableResult
    func changeEditPlans(
        creates: [EditPlan] = [],
        updates: [EditPlan] = [],
        deleteIds: [String] = [],
        actionName: String,
        reviewingClaimIds: Set<String> = [],
        updatingProductionRun: Bool = false,
        narrationValidation: PlanNarrationChangeValidation? = nil,
        synthesizedNarrationPublication: Bool = false
    ) throws -> EditPlanChangeReceipt {
        if editPlansLoadFailed {
            throw EditPlanValidationError.unreadablePlans
        }
        guard !synthesizedNarrationPublication || (updates.count == 1 && creates.isEmpty && deleteIds.isEmpty) else {
            throw EditPlanValidationError.invalidReference("Synthesized narration publication targets one existing plan.")
        }
        guard reviewingClaimIds.isEmpty || (updates.count == 1 && creates.isEmpty && deleteIds.isEmpty) else {
            throw EditPlanValidationError.invalidReference("Claim review must target one existing plan.")
        }
        guard !updatingProductionRun || (updates.count == 1 && creates.isEmpty && deleteIds.isEmpty) else {
            throw EditPlanValidationError.invalidReference("Production review must target one existing plan.")
        }
        guard Set(deleteIds).count == deleteIds.count else {
            throw EditPlanValidationError.invalidReference("Duplicate plan id in deleteIds.")
        }
        let before = editPlans
        var next = before

        for var plan in creates {
            guard plan.assembly == nil else {
                throw EditPlanValidationError.invalidReference("Assembly ownership is created only by applying a plan.")
            }
            guard plan.productionRun == nil else {
                throw EditPlanValidationError.invalidReference("Prepare a storyboard before creating production review state.")
            }
            if plan.narrationIntent?.narrator != nil {
                guard let narrationValidation else {
                    throw EditPlanValidationError.invalidReference("Choosing a narrator requires shared narration validation.")
                }
                try narrationValidation.validate(plan: plan, previous: nil, in: self)
            }
            plan = try EditPlan.validatedNew(
                plan,
                timelineId: plan.timelineId,
                fps: plan.fps,
                width: plan.width,
                height: plan.height,
                existingCount: next.count
            )
            guard timeline(for: plan.timelineId) != nil else {
                throw EditPlanValidationError.invalidReference("Timeline '\(plan.timelineId)' does not exist.")
            }
            next.append(plan)
        }
        var updatedPlans: [EditPlan] = []
        for var plan in updates {
            guard let index = next.firstIndex(where: { $0.id == plan.id }) else {
                throw EditPlanValidationError.invalidReference("Unknown planId '\(plan.id)'.")
            }
            let current = next[index]
            guard plan.assembly == current.assembly else {
                throw EditPlanValidationError.invalidReference("Assembly ownership changes require the shared assembly operation.")
            }
            if plan.narrationIntent?.narrator != current.narrationIntent?.narrator
                || (plan.productionRun != nil && plan.narration != current.narration) {
                if !synthesizedNarrationPublication {
                    guard let narrationValidation else {
                        throw EditPlanValidationError.invalidReference("Narrator and managed attachment changes require shared narration validation.")
                    }
                    try narrationValidation.validate(plan: plan, previous: current, in: self)
                }
            }
            guard updatingProductionRun || plan.productionRun == current.productionRun else {
                throw EditPlanValidationError.invalidReference("Production review changes require a storyboard operation.")
            }
            guard plan.timelineId == current.timelineId,
                  plan.fps == current.fps,
                  plan.width == current.width,
                  plan.height == current.height,
                   plan.createdAt == current.createdAt,
                   plan.sourceLedgerRevision == current.sourceLedgerRevision,
                   (synthesizedNarrationPublication || plan.narrationRevision == current.narrationRevision),
                  plan.status == current.status else {
                throw EditPlanValidationError.invalidReference("Plan identity, timeline, geometry, and status are immutable in an update.")
            }
            plan.status = .proposed
            plan.scriptBeats = try plan.scriptBeats?.map { try $0.validated() }
            plan.narrationIntent = try plan.narrationIntent?.validated()
            plan.narration = try plan.narration?.validated()
            if !synthesizedNarrationPublication {
                if plan.scriptBeats != current.scriptBeats || plan.narrationIntent != current.narrationIntent
                    || plan.narration != current.narration {
                    plan.narrationRevision = plan.scriptBeats == nil ? nil : UUID().uuidString
                    plan.narrationTiming = nil
                }
                if plan.scriptBeats != current.scriptBeats || plan.narrationIntent != current.narrationIntent
                    || plan.narration != current.narration {
                    plan.narrationSynthesisProof = nil
                }
            }
            plan.sourceLedger = try plan.sourceLedger?.validated(previous: current.sourceLedger, reviewingClaimIds: reviewingClaimIds)
            if let ledger = plan.sourceLedger, current.sourceLedger.map({ !ledger.hasSameEvidence(as: $0) }) ?? true {
                plan.sourceLedgerRevision = UUID().uuidString
            }
            let validated = try EditPlan.validatedNew(
                plan,
                timelineId: current.timelineId,
                fps: current.fps,
                width: current.width,
                height: current.height,
                existingCount: next.count - 1
            )
            var normalized = validated
            normalized.createdAt = current.createdAt
            normalized.status = current.status
            normalized.updatedAt = current.updatedAt
            normalized.invalidateStoryboardApproval(comparedTo: current)
            if !normalized.hasSameStoryboardIntent(as: current), current.status != .superseded {
                normalized.status = .proposed
            }
            guard normalized != current else { continue }
            normalized.updatedAt = Date()
            next[index] = normalized
            updatedPlans.append(normalized)
        }
        for id in deleteIds {
            guard next.contains(where: { $0.id == id }) else {
                throw EditPlanValidationError.invalidReference("Unknown planId '\(id)'.")
            }
        }
        next.removeAll { deleteIds.contains($0.id) }
        try EditPlan.ensureGlobalIDs(next)
        guard next != before else {
            return EditPlanChangeReceipt()
        }
        editPlans = next
        registerEditPlanSwap(before: before, after: next, actionName: actionName)
        onProjectCheckpointRequired?()
        return EditPlanChangeReceipt(
            created: next.filter { plan in before.allSatisfy { $0.id != plan.id } },
            updated: updatedPlans,
            deletedIds: deleteIds
        )
    }

    func changeEditPlanStatus(id: String, to status: EditPlanStatus, actionName: String, permitReserved: Bool = false) throws -> EditPlan {
        if editPlansLoadFailed {
            throw EditPlanValidationError.unreadablePlans
        }
        guard var plan = editPlans.first(where: { $0.id == id }) else {
            throw EditPlanValidationError.invalidReference("Unknown planId '\(id)'.")
        }
        try EditPlan.validatedStatusTransition(from: plan.status, to: status, permitReserved: permitReserved)
        if status == .approved, let run = plan.productionRun, run.phase != .approved || run.approvedRevision == nil {
            throw EditPlanValidationError.invalidReference("Managed production requires explicit approval of the current storyboard.")
        }
        guard plan.status != status else { return plan }
        let before = editPlans
        plan.status = status
        if status == .proposed, plan.productionRun != nil {
            plan.productionRun?.phase = .awaitingStoryboardApproval
            plan.productionRun?.approvedRevision = nil
        } else if status == .superseded, plan.productionRun != nil {
            plan.productionRun?.phase = .canceled
            plan.productionRun?.approvedRevision = nil
        }
        plan.updatedAt = Date()
        editPlans = before.map { $0.id == id ? plan : $0 }
        registerEditPlanSwap(before: before, after: editPlans, actionName: actionName)
        onProjectCheckpointRequired?()
        return plan
    }

    func reviewEditPlanClaims(id: String, claimIds: [String], ledgerRevision: String) throws -> EditPlanChangeReceipt {
        guard var plan = editPlan(id: id), let ledger = plan.sourceLedger else {
            throw EditPlanValidationError.invalidReference("Claim review requires an existing plan with a sourceLedger.")
        }
        guard plan.sourceLedgerRevision == ledgerRevision else {
            throw EditPlanValidationError.invalidReference("Source ledger changed; read and review the current evidence before approving claims.")
        }
        guard let ids = try ledger.validatedClaimIDs(claimIds) else {
            throw EditPlanValidationError.invalidReference("Claim review requires non-empty claimIds.")
        }
        let reviewed = Set(ids)
        for index in ledger.claims.indices where reviewed.contains(ledger.claims[index].claimId) {
            plan.sourceLedger?.claims[index].status = .reviewed
        }
        return try changeEditPlans(updates: [plan], actionName: L10n.string("Review Claims"), reviewingClaimIds: reviewed)
    }

    private func registerEditPlanSwap(before: [EditPlan], after: [EditPlan], actionName: String) {
        undo.register(actionName, withTarget: self) { vm in
            vm.editPlans = before
            vm.onProjectCheckpointRequired?()
            vm.registerEditPlanSwap(before: after, after: before, actionName: actionName)
        }
    }
}

extension EditPlan {
    func hasSameStoryboardIntent(as other: EditPlan) -> Bool {
        // The brief is part of the intent: a changed brief changes what the storyboard must show.
        storyboardIntent == other.storyboardIntent && brief == other.brief
    }

    mutating func invalidateStoryboardApproval(comparedTo previous: EditPlan) {
        guard !hasSameStoryboardIntent(as: previous), productionRun?.phase != .canceled else { return }
        productionRun?.phase = .stale
        productionRun?.approvedRevision = nil
        productionRun?.verifiedTimelineRevision = nil
    }

    static func ensureGlobalIDs(_ plans: [EditPlan]) throws {
        var seen = Set<String>()
        for plan in plans {
            for id in [plan.id] + plan.sections.map(\.id) + plan.shots.map(\.id)
                + (plan.scriptBeats ?? []).map(\.beatId) + (plan.soundCues ?? []).map(\.cueId) {
                guard seen.insert(id).inserted else { throw EditPlanValidationError.duplicateId(id) }
            }
        }
    }
}
