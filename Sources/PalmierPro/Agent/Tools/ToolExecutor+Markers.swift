import Foundation

private struct ManageMarkersInput: DecodableToolArgs {
    let action: String
    let markerId: String?
    let name: String?
    let startFrame: Int?
    let durationFrames: Int?
    let color: String?
    let comment: String?
    let status: String?
    static let allowedKeys: Set<String> = [
        "action", "markerId", "name", "startFrame", "durationFrames", "color", "comment",
        "status",
    ]
    var hasPatch: Bool {
        name != nil || startFrame != nil || durationFrames != nil || color != nil
            || comment != nil || status != nil
    }
}

extension ToolExecutor {
    func manageMarkers(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: ManageMarkersInput = try decodeToolArgs(args, path: "manage_markers")
        let status: TimelineMarker.Status? = try input.status.map {
            guard let status = TimelineMarker.Status(rawValue: $0) else {
                throw ToolError("status must be open, review, or resolved.")
            }
            return status
        }
        let receipt: TimelineMarkerChangeReceipt
        do {
            switch input.action {
            case "create":
                guard let name = input.name, let start = input.startFrame else {
                    throw ToolError("create requires name and startFrame.")
                }
                let marker = TimelineMarker(
                    name: name, startFrame: start,
                    durationFrames: input.durationFrames ?? 0,
                    color: try parseColorHex(input.color, path: "color") ?? TimelineMarker.defaultColor,
                    comment: input.comment ?? "",
                    status: status ?? .open
                )
                receipt = try editor.changeTimelineMarkers(
                    creates: [marker], actionName: "Add Marker (Agent)"
                )
            case "update":
                guard let id = input.markerId, input.hasPatch else {
                    throw ToolError("update requires markerId and at least one field to change.")
                }
                guard var marker = editor.timelineMarker(id: id) else {
                    throw ToolError("Unknown markerId '\(id)'.")
                }
                if let value = input.name { marker.name = value }
                if let value = input.startFrame { marker.startFrame = value }
                if let value = input.durationFrames { marker.durationFrames = value }
                if let value = try parseColorHex(input.color, path: "color") { marker.color = value }
                if let value = input.comment { marker.comment = value }
                if let status { marker.status = status }
                receipt = try editor.changeTimelineMarkers(
                    updates: [marker], actionName: "Change Marker (Agent)"
                )
            case "delete":
                guard let id = input.markerId else { throw ToolError("delete requires markerId.") }
                receipt = try editor.changeTimelineMarkers(
                    deleteIds: [id], actionName: "Delete Marker (Agent)"
                )
            default:
                throw ToolError("action must be create, update, or delete.")
            }
        } catch TimelineMarkerValidationError.invalidName {
            throw ToolError("Marker names must be non-empty single lines of at most \(TimelineMarker.maximumNameLength) characters.")
        } catch TimelineMarkerValidationError.invalidComment {
            throw ToolError("Marker comments must be at most \(TimelineMarker.maximumCommentLength) characters.")
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError("Marker frames must be non-negative integer ranges and every ID must exist.")
        }
        var payload: [String: Any] = [:]
        if let marker = receipt.created.first { payload["created"] = Self.timelineMarkerDict(marker) }
        if let marker = receipt.updated.first { payload["updated"] = Self.timelineMarkerDict(marker) }
        if let id = receipt.deletedIds.first { payload["deletedMarkerId"] = id }
        if payload.isEmpty { payload["noOp"] = true }
        return .ok(Self.jsonString(payload) ?? "{}")
    }
}
