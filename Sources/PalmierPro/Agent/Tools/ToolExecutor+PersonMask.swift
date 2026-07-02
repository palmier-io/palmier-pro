import Foundation

extension ToolExecutor {
    fileprivate struct RemoveBackgroundInput: DecodableToolArgs {
        let clipIds: [String]
        static let allowedKeys: Set<String> = ["clipIds"]
    }

    /// Bakes a per-person matte for each clip, joining an already-running bake if one exists.
    func removeBackground(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: RemoveBackgroundInput = try decodeToolArgs(args, path: "remove_background")
        guard !input.clipIds.isEmpty else { throw ToolError("clipIds is empty.") }
        for id in input.clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            guard clip.mediaType == .video else {
                throw ToolError("Clip \(id) is a \(clip.mediaType.rawValue) clip; remove_background needs a video clip.")
            }
        }

        var succeeded: [String] = []
        var failed: [(id: String, message: String)] = []
        for id in input.clipIds {
            do {
                try await editor.removeBackground(clipId: id).value
                succeeded.append(id)
            } catch {
                failed.append((id, error.localizedDescription))
            }
        }

        guard !succeeded.isEmpty else {
            let detail = failed.map { "\($0.id): \($0.message)" }.joined(separator: "; ")
            throw ToolError("Background removal failed on all \(failed.count) clip(s): \(detail)")
        }
        var summary = "Removed background on \(succeeded.count) clip\(succeeded.count == 1 ? "" : "s"): \(succeeded.joined(separator: ", "))."
        if !failed.isEmpty {
            summary += " Failed on \(failed.count): " + failed.map { "\($0.id) (\($0.message))" }.joined(separator: "; ") + "."
        }
        return .ok(summary + " Verify with inspect_timeline.")
    }
}
