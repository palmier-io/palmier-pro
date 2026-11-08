import Foundation

enum AgentDelegationTool {
    static let name = "delegate_work"
    static let schema = AgentToolSchema(
        name: name,
        description: "Run independent editing preparation in bounded parallel subagents. Supply all required source context; children cannot read or mutate the editor, call tools, approve production, inspect footage, spend credits, or spawn children. Parent validates findings and applies edits through existing tools. Successful drafts are not verified facts or visual-inspection evidence. Failed tasks report terminal reasons; fallback requires normal parent execution without repeating completed work.",
        inputSchema: [
            "type": "object", "additionalProperties": false,
            "properties": ["tasks": [
                "type": "array", "minItems": 1, "maxItems": 8,
                "items": ["type": "object", "additionalProperties": false,
                    "properties": [
                        "id": ["type": "string", "description": "Unique stable task ID."],
                        "objective": ["type": "string", "description": "One independent preparation outcome; no shared editor mutation."],
                        "context": ["type": "string", "description": "Immutable relevant script, evidence, IDs, and constraints. Never include credentials or claim unperformed inspection."],
                    ], "required": ["id", "objective", "context"],
                ],
            ]], "required": ["tasks"],
        ]
    )

    static let instructions = """

    ## Parallel independent preparation
    Default to delegate_work for two or more independent preparation tasks, such as separate scene narration drafts, supplied-evidence review, or alternative edit proposals. Gather relevant context first. Children receive immutable text and have no tools, editor access, approval authority, or spending authority. Do not delegate dependent steps or full-span face/rights attestations. You remain responsible for validating results against current source state and using shared editor tools, undo, cancellation, and production gates. Never treat child findings as user approval or verified delivery. Do not repeat completed work. If delegation reports fallback_required, perform only unfinished work normally in this run; do not respawn repeatedly. Refusal, authorization, credits, and production blockers are not reasons to bypass a gate or switch models.
    """

    static let fallbackInstructions = """

    Parallel preparation is unavailable for this run. Complete unfinished preparation normally through existing tools, preserving completed results and every approval, rights, visual-uniqueness, cancellation, and undo rule. Do not retry delegate_work or silently change provider/model. Authorization, credit, refusal, and production failures remain blockers.
    """

    static let blockedInstructions = """

    Parallel preparation stopped after a refusal, permission, authentication, or credit blocker. Do not retry delegation or execute denied work normally. Report the blocker and request its resolution. Completed drafts do not authorize edits, spending, inspection attestations, or production. Unrelated permitted work still uses existing tools and gates.
    """

    static func tasks(from input: String) throws -> [AgentDelegationTask] {
        guard let data = input.data(using: .utf8), data.count <= 262_144,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["tasks"], let tasks = object["tasks"] as? [[String: Any]],
              (1...8).contains(tasks.count) else { throw ToolError("delegate_work requires 1–8 independent tasks.") }
        return try tasks.map { task in
            guard Set(task.keys) == ["id", "objective", "context"], let id = task["id"] as? String,
                  let objective = task["objective"] as? String, let context = task["context"] as? String else {
                throw ToolError("Every delegated task requires exact string id, objective, and context fields.")
            }
            return AgentDelegationTask(id: id, objective: objective, context: context)
        }
    }
}

extension AgentService {
    func executeDelegation(input: String, client: any AgentClient, delegation: AgentDelegation,
                           context: AgentRequestContext, settings: AgentRunSettings) async -> ToolResult {
        let runEditor = editor
        let revision = runEditor?.visualReviewRevision
        let plansRevision = runEditor?.editPlansRevision
        do {
            let tasks = try AgentDelegationTool.tasks(from: input)
            let receipt = try await delegation.run(tasks: tasks, client: client,
                system: AgentInstructions.serverInstructions, requestContext: context)
            try Task.checkCancellation()
            guard currentSessionId == context.conversationID, editor === runEditor,
                  runEditor?.visualReviewRevision == revision, runEditor?.editPlansRevision == plansRevision,
                  snapshotRunSettings() == settings else {
                return .error("delegation_stale: editor, storyboard, session, or model changed; discard drafts and prepare against current state.")
            }
            let data = try await Self.encodeDelegation(receipt)
            try Task.checkCancellation()
            guard currentSessionId == context.conversationID, editor === runEditor,
                  runEditor?.visualReviewRevision == revision, runEditor?.editPlansRevision == plansRevision,
                  snapshotRunSettings() == settings else { return .error("delegation_stale: context changed during result preparation.") }
            return ToolResult(content: [.text(data)], isError: receipt.tasks.contains { $0.status != .completed })
        } catch is CancellationError {
            return .error("delegation_canceled")
        } catch {
            return .error("delegation_failed: \(error.localizedDescription)")
        }
    }

    @concurrent private static func encodeDelegation(_ receipt: AgentDelegationReceipt) async throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(receipt), as: UTF8.self)
    }
}
