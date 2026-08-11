import Foundation

extension EditorViewModel {
    func createMatte(
        hex: String,
        aspect: MatteAspect = .project,
        folderId: String? = nil,
        name: String? = nil
    ) async throws -> MediaAsset {
        guard projectURL != nil else { throw Matte.Error.noProject }
        let d = aspect.pixelSize(timelineWidth: timeline.width, timelineHeight: timeline.height)
        let filename = "matte-\(UUID().uuidString.prefix(8)).png"
        let data = try Matte.png(hex: hex, width: d.width, height: d.height)
        let stagedURL = try await Task.detached(priority: .userInitiated) { try FileIO.stageData(data, pathExtension: "png") }.value
        let destinationURL = try await commitStagedProjectMedia(stagedURL, filename: filename)
        let asset = MediaAsset(
            url: destinationURL, type: .image,
            name: name ?? (aspect == .project ? "Matte · \(d.width)×\(d.height)" : "Matte · \(aspect.rawValue)")
        )
        asset.folderId = folderId
        importMediaAsset(asset)
        await finalizeImportedAsset(asset)
        onProjectCheckpointRequired?()
        return asset
    }
}
