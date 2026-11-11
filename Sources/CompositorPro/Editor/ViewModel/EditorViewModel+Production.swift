import Foundation

extension EditorViewModel {
    /// Commits production-run metadata without creating an undo entry.
    ///
    /// The run's phase, steps, and findings are bookkeeping about work already
    /// performed; the edits themselves own their undo entries.
    func commitProductionRunMetadata(_ run: ProductionRun, plan: EditPlan) throws {
        try undo.withoutRegistration {
            try commitProductionRun(run, plan: plan, actionName: L10n.string("Record Production Review"))
        }
    }

    /// The persisted production run for a plan, if it has one.
    func productionRun(planId: String) -> ProductionRun? {
        editPlan(id: planId)?.productionRun
    }

    /// Current production status for a plan.
    func productionStatus(planId: String) -> ProductionStatus {
        productionCoordinator.status(planId: planId)
    }

    /// Stops every in-flight production run. A closed or replaced project never
    /// continues editing the timeline behind the user's back.
    func cancelProductionRuns() {
        productionCoordinator.cancelAll()
    }
}
