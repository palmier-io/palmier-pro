import Foundation

extension ToolExecutor {
    private struct EditPilotInput: DecodableToolArgs {
        let action: String?
        let direction: String?
        let arrangementId: String?
        let mediaRefs: [String]?
        let musicMediaRef: String?
        let targetDurationSeconds: Double?
        let pacing: String?
        let blockId: String?
        let isApproved: Bool?
        let sourceStartSeconds: Double?
        let sourceEndSeconds: Double?
        let caption: String?
        let approveAll: Bool?

        static let allowedKeys: Set<String> = [
            "action", "direction", "arrangementId", "mediaRefs", "musicMediaRef",
            "targetDurationSeconds", "pacing", "blockId", "isApproved",
            "sourceStartSeconds", "sourceEndSeconds", "caption", "approveAll",
        ]
    }

    /// Handles the EditPilot planner tool: direction → suggested timeline arrangement.
    func editPilot(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: EditPilotInput = try decodeToolArgs(args, path: "edit_pilot")
        guard let rawAction = input.action, let action = EditPilotAction(rawValue: rawAction) else {
            let valid = ["propose", "read", "review", "approve_all", "apply"].joined(separator: ", ")
            throw ToolError("edit_pilot requires a valid action: \(valid).")
        }

        switch action {
        case .propose:
            guard let direction = input.direction?.trimmingCharacters(in: .whitespacesAndNewlines), !direction.isEmpty else {
                throw ToolError("edit_pilot propose action requires a non-empty direction string.")
            }
            let pacing = input.pacing.flatMap { EditPilotPacing(rawValue: $0) }
            do {
                let arrangement = try await editor.proposeEditPilotArrangement(
                    direction: direction,
                    mediaRefs: input.mediaRefs,
                    musicMediaRef: input.musicMediaRef,
                    targetDurationSeconds: input.targetDurationSeconds,
                    pacing: pacing
                )
                let data = try JSONEncoder().encode(arrangement)
                return .ok(String(decoding: data, as: UTF8.self))
            } catch let err as EditPilotError {
                throw ToolError(err.localizedDescription)
            }

        case .read:
            guard let id = input.arrangementId, !id.isEmpty else {
                throw ToolError("edit_pilot read action requires arrangementId.")
            }
            guard let arrangement = editor.editPilotArrangements[id] else {
                throw ToolError("EditPilot arrangement '\(id)' not found.")
            }
            let data = try JSONEncoder().encode(arrangement)
            return .ok(String(decoding: data, as: UTF8.self))

        case .review:
            guard let id = input.arrangementId, !id.isEmpty else {
                throw ToolError("edit_pilot review action requires arrangementId.")
            }
            if input.approveAll == true {
                do {
                    let arrangement = try editor.approveAllEditPilotBlocks(arrangementId: id)
                    let data = try JSONEncoder().encode(arrangement)
                    return .ok(String(decoding: data, as: UTF8.self))
                } catch let err as EditPilotError {
                    throw ToolError(err.localizedDescription)
                }
            }
            guard let blockId = input.blockId, !blockId.isEmpty else {
                throw ToolError("edit_pilot review action requires blockId or approveAll:true.")
            }
            do {
                let arrangement = try editor.reviewEditPilotBlock(
                    arrangementId: id,
                    blockId: blockId,
                    isApproved: input.isApproved,
                    sourceStartSeconds: input.sourceStartSeconds,
                    sourceEndSeconds: input.sourceEndSeconds,
                    caption: input.caption
                )
                let data = try JSONEncoder().encode(arrangement)
                return .ok(String(decoding: data, as: UTF8.self))
            } catch let err as EditPilotError {
                throw ToolError(err.localizedDescription)
            }

        case .approveAll:
            guard let id = input.arrangementId, !id.isEmpty else {
                throw ToolError("edit_pilot approve_all action requires arrangementId.")
            }
            do {
                let arrangement = try editor.approveAllEditPilotBlocks(arrangementId: id)
                let data = try JSONEncoder().encode(arrangement)
                return .ok(String(decoding: data, as: UTF8.self))
            } catch let err as EditPilotError {
                throw ToolError(err.localizedDescription)
            }

        case .apply:
            guard let id = input.arrangementId, !id.isEmpty else {
                throw ToolError("edit_pilot apply action requires arrangementId.")
            }
            do {
                let receipt = try editor.applyEditPilotArrangement(arrangementId: id)
                let data = try JSONEncoder().encode(receipt)
                return .ok(String(decoding: data, as: UTF8.self))
            } catch let err as EditPilotError {
                throw ToolError(err.localizedDescription)
            }
        }
    }
}
