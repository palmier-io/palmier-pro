import Foundation

extension ToolExecutor {
    /// Search HyperFrames catalog. Can run without an active project (read-only).
    func searchHyperframesCatalog(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try Task.checkCancellation()
        try validateUnknownKeys(args, allowed: ["query", "category", "limit"], path: "search_hyperframes_catalog")

        let query = args.string("query") ?? ""
        let category = args.string("category")

        var filtered = HyperframesCatalog.shared.blocks
        if let category, !category.isEmpty {
            filtered = filtered.filter { $0.category == category }
        }
        if !query.isEmpty {
            filtered = filtered.filter { block in
                block.name.lowercased().contains(query) ||
                    block.description.lowercased().contains(query) ||
                    block.tags.contains { $0.lowercased().contains(query) }
            }
        }
        var resultBlocks: [[String: Any]] = []
        for block in filtered {
            var blockInfo: [String: Any] = [
                "id": block.id,
                "name": block.name,
                "category": block.category,
                "tags": block.tags,
                "description": block.description,
                "path": block.path,
                "assets": block.assets,
                "preview": block.preview,
                "minVersion": block.minVersion,
                "defaultDurationFrames": block.defaultDurationFrames,
                "requiredAdapters": block.requiredAdapters,
            ]
            if !HyperframesCatalog.base.isEmpty,
               let base = URL(string: HyperframesCatalog.base),
               let preview = block.preview,
               let previewURL = HyperframesBlock.resolve(preview, base: base),
               let data = try? Data(contentsOf: previewURL),
               let previewB64 = base64String(from: data) {
                blockInfo["previewBase64"] = previewB64
            }
            resultBlocks.append(blockInfo)
        }
        return .ok(jsonString(["blocks": resultBlocks]) ?? "{}")
    }

    /// Install a HyperFrames block into the project's media library.
    func insertHyperframesBlock(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try Task.checkCancellation()
        try validateUnknownKeys(args, allowed: ["blockId"], path: "insert_hyperframes_block")
        guard let blockId = args.string("blockId") else {
            throw ToolError("Missing required field: blockId")
        }
        guard let block = HyperframesCatalog.shared.block(id: blockId) else {
            return .error("Unknown HyperFrames block id: \(blockId)")
        }
        guard !HyperframesCatalog.base.isEmpty,
              let base = URL(string: HyperframesCatalog.base),
              !block.assets.isEmpty else {
            return .error("Hyperframes catalog mirror not configured or block has no assets")
        }
        let resolvedAssets = block.assets.compactMap { HyperframesBlock.resolve($0, base: base) }
        guard !resolvedAssets.isEmpty else {
            return .error("No assets found for block \(blockId)")
        }
        let folderId = args.string("folderId") ?? editor.mediaPanelCurrentFolderId
        let result = try await editor.importFinderItems(resolvedAssets, into: folderId, finalize: true)
        return .ok(jsonString([
            "status": "ok",
            "blockId": blockId,
            "message": "Installed HyperFrames block \(block.name) as media assets."
        ]) ?? "{}")
    }

    // MARK: - JSON helpers

    private func base64String(from data: Data) -> String? {
        data.base64EncodedString()
    }

    private func jsonString(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}