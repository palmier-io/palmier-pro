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
        actionName: String
    ) throws -> EditPlanChangeReceipt {
        if editPlansLoadFailed {
            throw EditPlanValidationError.unreadablePlans
        }
        guard Set(deleteIds).count == deleteIds.count else {
            throw EditPlanValidationError.invalidReference("Duplicate plan id in deleteIds.")
        }
        let before = editPlans
        var next = before

        for var plan in creates {
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
            guard plan.timelineId == current.timelineId,
                  plan.fps == current.fps,
                  plan.width == current.width,
                  plan.height == current.height,
                  plan.createdAt == current.createdAt,
                  plan.status == current.status else {
                throw EditPlanValidationError.invalidReference("Plan identity, timeline, geometry, and status are immutable in an update.")
            }
            plan.updatedAt = Date()
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
        guard plan.status != status else { return plan }
        let before = editPlans
        plan.status = status
        plan.updatedAt = Date()
        editPlans = before.map { $0.id == id ? plan : $0 }
        registerEditPlanSwap(before: before, after: editPlans, actionName: actionName)
        onProjectCheckpointRequired?()
        return plan
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
    static func ensureGlobalIDs(_ plans: [EditPlan]) throws {
        var seen = Set<String>()
        for plan in plans {
            for id in [plan.id] + plan.sections.map(\.id) + plan.shots.map(\.id) {
                guard seen.insert(id).inserted else { throw EditPlanValidationError.duplicateId(id) }
            }
        }
    }
}
