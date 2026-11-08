import Foundation

extension EditorViewModel {
    func createMatte(
        hex: String,
        aspect: MatteAspect = .project,
        folderId: String? = nil,
        name: String? = nil
    ) async throws -> MediaAsset {
        try await projectPackageCoordinator.withMutation { lease in
            try await self.performMatteCreation(hex: hex, aspect: aspect, folderId: folderId, name: name, lease: lease)
        }
    }

    private func performMatteCreation(
        hex: String, aspect: MatteAspect, folderId: String?, name: String?,
        lease: ProjectPackageCoordinator.MutationLease
    ) async throws -> MediaAsset {
        guard let package = projectURL else { throw Matte.Error.noProject }
        let d = aspect.pixelSize(timelineWidth: timeline.width, timelineHeight: timeline.height)
        let filename = "matte-\(UUID().uuidString).png"
        let stagedURL = try await projectPackageCoordinator.io.perform {
            let data = try Matte.png(hex: hex, width: d.width, height: d.height)
            return try FileIO.stageData(data, pathExtension: "png")
        }
        let asset = MediaAsset(
            url: package.appendingPathComponent("media/\(filename)"), type: .image,
            name: name ?? (aspect == .project ? "Matte · \(d.width)×\(d.height)" : "Matte · \(aspect.rawValue)")
        )
        asset.folderId = folderId
        _ = try await commitStagedProjectMedia(stagedURL, filename: filename, lease: lease, validate: {
            if let id = folderId, self.folder(id: id) == nil { throw CocoaError(.fileNoSuchFile) }
        }) { destination in
            asset.url = destination
            self.importMediaAsset(asset)
        }
        await finalizeImportedAsset(asset)
        onProjectCheckpointRequired?()
        return asset
    }
}
