import Foundation

extension ToolExecutor {
    private struct ProducePlanInput: DecodableToolArgs {
        let planId: String
        static let allowedKeys: Set<String> = ["planId"]
    }

    /// Runs the persisted production plan: assembly, measured mix, rendered
    /// review, and delivery. The run resumes from its persisted step ledger, so
    /// a retry never repeats completed work.
    func producePlan(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: ProducePlanInput = try decodeToolArgs(args, path: "produce_plan")
        let status: ProductionStatus
        do {
            status = try await editor.productionCoordinator.produce(planId: input.planId)
        } catch let error as ProductionError {
            throw ToolError(error.errorDescription ?? "Production could not continue.")
        }
        guard let json = Self.jsonString(status.receipt) else {
            throw ToolError("produce_plan: could not encode the production receipt.")
        }
        return .ok(json)
    }

    /// The persisted production state for a plan, without changing anything.
    func productionStatus(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: ProducePlanInput = try decodeToolArgs(args, path: "production_status")
        let status = editor.productionStatus(planId: input.planId)
        guard let json = Self.jsonString(status.receipt) else {
            throw ToolError("production_status: could not encode the production receipt.")
        }
        return .ok(json)
    }
}
