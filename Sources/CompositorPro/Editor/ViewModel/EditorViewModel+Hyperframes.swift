import Foundation

extension EditorViewModel {
    /// Installs a HyperFrames block into the project's media library. The block
    /// must be present in the local catalog mirror. Uses the same domain operation
    /// as `import_media` — one undo entry, same manifest/undo path, no second
    /// implementation of the install rules.
    func installHyperframesBlock(_ block: HyperframesBlock, into folderId: String? = nil) async throws -> MediaImportSummary {
        let mirrorBase = HyperframesCatalog.base
        guard !mirrorBase.isEmpty, let base = URL(string: mirrorBase) else {
            throw ToolError("Hyperframes catalog mirror not configured")
        }
        let resolvedAssets = block.assets.compactMap { HyperframesBlock.resolve($0, base: base) }
        guard !resolvedAssets.isEmpty else {
            throw ToolError("HyperFrames block has no resolvable assets")
        }
        let resolvedFolderId = folderId ?? self.mediaPanelCurrentFolderId
        return try await importFinderItems(resolvedAssets, into: resolvedFolderId, finalize: true)
    }
}