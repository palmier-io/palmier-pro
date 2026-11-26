import Foundation

extension ToolExecutor {
    fileprivate struct ApplyTransitionInput: DecodableToolArgs {
        let outgoingClipId: String?
        let incomingClipId: String?
        let type: String?
        let direction: String?
        let durationFrames: Int?
        static let allowedKeys: Set<String> = [
            "outgoingClipId", "incomingClipId", "type", "direction", "durationFrames",
        ]
    }

    /// Applies a first-class transition between two adjacent same-track clips. The timeline
    /// clips stay sequential; dissolve, slide and push render their overlap through an
    /// upper-track copy, while dip-to-black is expressed as opacity keyframes. One undo step.
    func applyTransition(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: ApplyTransitionInput = try decodeToolArgs(args, path: "apply_transition")
        guard let outgoingId = input.outgoingClipId, !outgoingId.isEmpty else {
            throw ToolError("apply_transition requires outgoingClipId.")
        }
        guard let incomingId = input.incomingClipId, !incomingId.isEmpty else {
            throw ToolError("apply_transition requires incomingClipId.")
        }
        guard let rawType = input.type, let type = TransitionType(rawValue: rawType) else {
            throw ToolError("type must be one of: dissolve, dipToBlack, slide, push.")
        }
        let direction: TransitionDirection?
        if let rawDirection = input.direction {
            guard let parsed = TransitionDirection(rawValue: rawDirection) else {
                throw ToolError("direction must be one of: left, right, up, down.")
            }
            direction = parsed
        } else {
            direction = nil
        }
        guard let duration = input.durationFrames else {
            throw ToolError("apply_transition requires durationFrames.")
        }
        do {
            let record = try editor.applyTransition(
                outgoingId: outgoingId, incomingId: incomingId,
                type: type, direction: direction, durationFrames: duration
            )
            var payload = record.receipt
            payload["notes"] = [
                "One undo step removes the transition, its overlay clips, and restores the previous audio fades.",
            ]
            return .ok(Self.jsonString(payload) ?? "{}")
        } catch let error as TransitionValidationError {
            throw ToolError(error.errorDescription ?? "Invalid transition.")
        }
    }

    /// Removes a transition by id: deletes its overlay clips, clears the keyframes it wrote,
    /// restores the previous audio fades, and drops the record. One undo step.
    func removeTransition(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["transitionId"], path: "remove_transition")
        guard let id = args.string("transitionId"), !id.isEmpty else {
            throw ToolError("remove_transition requires transitionId.")
        }
        do {
            let record = try editor.removeTransition(id: id)
            var payload = record.receipt
            payload["removed"] = true
            return .ok(Self.jsonString(payload) ?? "{}")
        } catch let error as TransitionValidationError {
            throw ToolError(error.errorDescription ?? "Invalid transition.")
        }
    }
}
