import Foundation

fileprivate struct AddMarkersInput: DecodableToolArgs {
    let entries: [Entry]
    static let allowedKeys: Set<String> = ["entries"]

    struct Entry: DecodableToolArgs {
        let frame: Int
        let label: String?
        let color: String?
        static let allowedKeys: Set<String> = ["frame", "label", "color"]
    }
}

fileprivate struct SetMarkerPropertiesInput: DecodableToolArgs {
    let markerIds: [String]
    let frame: Int?
    let label: String?
    let color: String?
    static let allowedKeys: Set<String> = ["markerIds", "frame", "label", "color"]
}

extension ToolExecutor {
    func addMarkers(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: AddMarkersInput = try decodeToolArgs(args, path: "add_markers")
        guard !input.entries.isEmpty else { throw ToolError("Missing or empty 'entries' array") }
        if let raws = args["entries"] as? [Any] {
            for (idx, raw) in raws.enumerated() {
                if let dict = raw as? [String: Any] {
                    try validateUnknownKeys(dict, allowed: AddMarkersInput.Entry.allowedKeys, path: "entries[\(idx)]")
                }
            }
        }
        for (idx, entry) in input.entries.enumerated() where entry.frame < 0 {
            throw ToolError("entries[\(idx)].frame must be >= 0")
        }

        let drafts = input.entries.map {
            TimelineMarkerDraft(frame: $0.frame, label: $0.label, color: $0.color)
        }
        let markers = editor.addTimelineMarkers(drafts)
        return .ok(markerJSON(["markers": markers.map(Self.markerInfo)]))
    }

    func setMarkerProperties(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: SetMarkerPropertiesInput = try decodeToolArgs(args, path: "set_marker_properties")
        guard !input.markerIds.isEmpty else { throw ToolError("Missing or empty 'markerIds' array") }
        guard input.frame != nil || input.label != nil || input.color != nil else {
            throw ToolError("Provide at least one of frame, label, or color")
        }
        if let frame = input.frame, frame < 0 {
            throw ToolError("frame must be >= 0")
        }
        for id in input.markerIds where editor.timelineMarker(id: id) == nil {
            throw ToolError("Marker not found: \(id)")
        }

        let updated = editor.updateTimelineMarkers(
            ids: Set(input.markerIds),
            frame: input.frame,
            label: input.label,
            color: input.color
        )
        return .ok(markerJSON(["markers": updated.map(Self.markerInfo)]))
    }

    func removeMarkers(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["markerIds"], path: "remove_markers")
        let markerIds = args.stringArray("markerIds")
        guard !markerIds.isEmpty else { throw ToolError("Missing or empty 'markerIds' array") }
        for id in markerIds where editor.timelineMarker(id: id) == nil {
            throw ToolError("Marker not found: \(id)")
        }
        editor.removeTimelineMarkers(ids: Set(markerIds))
        return .ok(markerJSON(["removedMarkerIds": markerIds]))
    }

    private static func markerInfo(_ marker: TimelineMarker) -> [String: Any] {
        var out: [String: Any] = [
            "id": marker.id,
            "frame": marker.frame,
            "label": marker.label,
        ]
        if let color = marker.color { out["color"] = color }
        return out
    }

    private func markerJSON(_ obj: [String: Any]) -> String {
        Self.jsonString(obj) ?? "{}"
    }
}
