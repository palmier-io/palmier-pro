import Foundation

extension ToolExecutor {
    private struct InsertHyperframesBlockInput: DecodableToolArgs {
        let blockId: String
        let placeOnTimeline: Bool?
        let trackIndex: Int?
        let startFrame: Int?
        let durationFrames: Int?
        let motionPreset: String?
        let blendMode: String?
        let opacity: Double?
        let scale: Double?
        let folderId: String?

        static let allowedKeys: Set<String> = [
            "blockId", "placeOnTimeline", "trackIndex", "startFrame",
            "durationFrames", "motionPreset", "blendMode", "opacity",
            "scale", "folderId"
        ]
    }

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
                "preview": block.preview as Any,
                "minVersion": block.minVersion as Any,
                "defaultDurationFrames": block.defaultDurationFrames as Any,
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
        return .ok(Self.jsonString(["blocks": resultBlocks]) ?? "{}")
    }

    /// Install a HyperFrames block into the project's media library and optionally place it onto the timeline.
    func insertHyperframesBlock(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try Task.checkCancellation()
        let input: InsertHyperframesBlockInput = try decodeToolArgs(args, path: "insert_hyperframes_block")

        guard let block = HyperframesCatalog.shared.block(id: input.blockId) else {
            return .error("Unknown HyperFrames block id: \(input.blockId)")
        }

        let preset: MotionPreset?
        if let raw = input.motionPreset {
            guard let parsed = MotionPreset(rawValue: raw) else {
                let options = MotionPreset.allCases.map(\.rawValue).joined(separator: ", ")
                throw ToolError("motionPreset must be one of: \(options).")
            }
            preset = parsed
        } else {
            preset = nil
        }

        let blendMode: BlendMode?
        if let raw = input.blendMode {
            guard let parsed = BlendMode(rawValue: raw) else {
                let options = BlendMode.allCases.map(\.rawValue).joined(separator: ", ")
                throw ToolError("blendMode must be one of: \(options).")
            }
            blendMode = parsed
        } else {
            blendMode = nil
        }

        if let duration = input.durationFrames, duration < 1 {
            throw ToolError("durationFrames must be at least 1.")
        }
        if let opacity = input.opacity, (opacity < 0.0 || opacity > 1.0) {
            throw ToolError("opacity must be between 0.0 and 1.0.")
        }
        if let scale = input.scale, scale <= 0 {
            throw ToolError("scale must be greater than 0.")
        }

        let shouldPlace = input.placeOnTimeline ?? (
            input.trackIndex != nil || input.startFrame != nil || input.durationFrames != nil ||
            input.motionPreset != nil || input.blendMode != nil || input.opacity != nil || input.scale != nil
        )

        if shouldPlace {
            let receipt = try await editor.insertAndPlaceHyperframesBlock(
                blockId: input.blockId,
                folderId: input.folderId,
                trackIndex: input.trackIndex,
                startFrame: input.startFrame,
                durationFrames: input.durationFrames,
                motionPreset: preset,
                blendMode: blendMode,
                opacity: input.opacity,
                scale: input.scale
            )
            return .ok(Self.jsonString([
                "status": "ok",
                "blockId": receipt.blockId,
                "blockName": receipt.blockName,
                "assetCount": receipt.assetCount,
                "placedClipIds": receipt.placedClipIds,
                "trackIndex": receipt.trackIndex,
                "startFrame": receipt.startFrame,
                "durationFrames": receipt.durationFrames,
                "motionPreset": receipt.motionPreset as Any,
                "message": "Installed and placed HyperFrames block '\(receipt.blockName)' on track \(receipt.trackIndex) at frame \(receipt.startFrame)."
            ]) ?? "{}")
        } else {
            let summary = try await editor.installHyperframesBlock(block, into: input.folderId)
            return .ok(Self.jsonString([
                "status": "ok",
                "blockId": input.blockId,
                "blockName": block.name,
                "assetCount": summary.assetCount,
                "message": "Installed HyperFrames block '\(block.name)' into media library."
            ]) ?? "{}")
        }
    }

    /// Opens a live WebView preview tab for a HyperFrames block with project styling.
    func previewHyperframesBlock(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try Task.checkCancellation()
        try validateUnknownKeys(args, allowed: ["blockId", "parameters"], path: "preview_hyperframes_block")

        guard let blockId = args.string("blockId"), !blockId.isEmpty else {
            throw ToolError("blockId is required.")
        }

        guard let spec = HyperframesCatalogWrapper.inspectBlock(id: blockId) else {
            throw ToolError("Unknown HyperFrames block id: \(blockId)")
        }

        let params = args["parameters"] as? [String: String] ?? [:]
        let designSpec = await MainActor.run { editor.exportCurrentDesignSpec() }
        let html = HyperframesCatalogWrapper.generateTemplateHTML(for: spec, parameters: params, designSpec: designSpec)

        let duration = spec.defaultDurationFrames ?? 150
        await MainActor.run {
            editor.openHyperframesPreviewTab(
                id: spec.id,
                name: spec.name,
                html: html,
                durationFrames: duration
            )
        }

        return .ok(Self.jsonString([
            "status": "ok",
            "blockId": spec.id,
            "blockName": spec.name,
            "durationFrames": duration,
            "message": "Opened live preview for HyperFrames block '\(spec.name)'."
        ]) ?? "{}")
    }

    // MARK: - Helpers

    private func base64String(from data: Data) -> String? {
        data.base64EncodedString()
    }
}
