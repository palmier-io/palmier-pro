import Foundation

extension EditorViewModel {
    struct MapSceneReceipt {
        var asset: MediaAsset
        var clipId: String?
        var warnings: [String]
    }

    enum MapSceneBuildError: LocalizedError {
        case noProject

        var errorDescription: String? {
            "Save the project first — map scenes are stored in its package."
        }
    }

    func prepareMapScene(_ spec: MapSceneSpec, name: String?, addToTimeline: Bool = false, startFrame: Int = 0) async throws -> MapSceneReceipt {
        try await projectPackageCoordinator.withMutation { lease in
            try await self.performMapScene(spec, lease: lease, name: name, addToTimeline: addToTimeline, startFrame: startFrame)
        }
    }

    private func performMapScene(
        _ spec: MapSceneSpec,
        lease: ProjectPackageCoordinator.MutationLease,
        name: String?,
        addToTimeline: Bool,
        startFrame: Int
    ) async throws -> MapSceneReceipt {
        guard let package = projectURL else { throw MapSceneBuildError.noProject }
        try Task.checkCancellation()
        let data = try MapSceneLottie.data(for: spec)
        let tempJSON = try await projectPackageCoordinator.io.perform {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("map-\(spec.digest)-\(UUID().uuidString).json")
            try data.write(to: url, options: [.atomic])
            return url
        }
        defer { try? FileManager.default.removeItem(at: tempJSON) }
        guard LottieVideoGenerator.isLottie(at: tempJSON) else {
            throw MapSceneError.invalidSpec("Generated map animation failed the Lottie signature check.")
        }
        let size = CGSize(width: spec.width, height: spec.height)
        let baked = try await LottieVideoGenerator.lottieVideo(for: tempJSON, mediaRef: "map-\(spec.digest)", size: size)
        try Task.checkCancellation()
        try projectPackageCoordinator.validate(lease)

        let filename = "map-\(spec.digest).mov"
        let asset = MediaAsset(
            url: package.appendingPathComponent("media/\(filename)"),
            type: .video,
            name: name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? name! : "Map \(spec.digest.prefix(8))",
            duration: Double(spec.durationFrames) / Double(MapSceneLottie.fps)
        )
        asset.sourceWidth = spec.width
        asset.sourceHeight = spec.height
        asset.sourceFPS = Double(MapSceneLottie.fps)

        var placedClipId: String?
        var warnings: [String] = []
        _ = try await commitStagedProjectMedia(baked, filename: filename, lease: lease) { destination in
            asset.url = destination
            self.importMediaAsset(asset)
            self.searchIndex.schedule(asset)
            self.prepareMediaVisuals(for: asset)
            if addToTimeline {
                let trackIndex = self.timeline.tracks.firstIndex(where: { $0.type == .video })
                    ?? self.insertTrack(at: 0, type: .video)
                placedClipId = self.placeClip(asset: asset, trackIndex: trackIndex,
                    startFrame: max(0, startFrame), durationFrames: spec.durationFrames, addLinkedAudio: false).first
                if placedClipId == nil { warnings.append("The map scene was created but could not be placed on the timeline.") }
            }
            self.onProjectCheckpointRequired?()
        }
        return MapSceneReceipt(asset: asset, clipId: placedClipId, warnings: warnings)
    }
}
