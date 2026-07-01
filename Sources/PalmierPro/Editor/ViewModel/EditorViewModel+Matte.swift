import Foundation

extension EditorViewModel {
    func createMatte(
        hex: String,
        aspect: MatteAspect = .project,
        folderId: String? = nil,
        name: String? = nil
    ) async throws -> MediaAsset {
        guard let projectURL else { throw Matte.Error.noProject }
        let d = aspect.pixelSize(timelineWidth: timeline.width, timelineHeight: timeline.height)
        let dest = projectURL
            .appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
            .appendingPathComponent("matte-\(UUID().uuidString.prefix(8)).png")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Matte.png(hex: hex, width: d.width, height: d.height)
        try await Task.detached(priority: .userInitiated) { try FileIO.writeData(data, to: dest) }.value
        let asset = MediaAsset(
            url: dest, type: .image,
            name: name ?? (aspect == .project ? "Matte · \(d.width)×\(d.height)" : "Matte · \(aspect.rawValue)")
        )
        asset.folderId = folderId
        importMediaAsset(asset)
        await finalizeImportedAsset(asset)
        onProjectCheckpointRequired?()
        return asset
    }
}
