import Foundation

extension EditorViewModel {
    struct MapSceneReceipt {
        let asset: MediaAsset
        let clipId: String?
        let changed: Bool
        let reused: Bool
        let placementFrames: Int?
    }

    func prepareMapScene(
        _ input: MapSceneInput, name: String? = nil, addToTimeline: Bool = false, startFrame: Int = 0,
        render: MapSceneRenderOperation = MapSceneRenderer.render
    ) async throws -> MapSceneReceipt {
        guard (0...maxFrameArg).contains(startFrame) else { throw ClipPlacement.Failure.invalidRange }
        let requestedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestedName { _ = try MapSceneSpec.text(requestedName, maximum: 160) }
        return try await projectPackageCoordinator.withMutation { lease in
            try await self.performMapScene(input, name: requestedName, addToTimeline: addToTimeline,
                startFrame: startFrame, lease: lease, render: render)
        }
    }

    private func performMapScene(
        _ input: MapSceneInput, name: String?, addToTimeline: Bool, startFrame: Int,
        lease: ProjectPackageCoordinator.MutationLease, render: MapSceneRenderOperation
    ) async throws -> MapSceneReceipt {
        guard let package = projectURL else { throw MapSceneError.invalidSpec("Save the project before building a map scene.") }
        let timelineId = timeline.id, fps = timeline.fps, width = timeline.width, height = timeline.height
        var references = Set((input.regions ?? []).compactMap(\.imageMediaRef) + (input.objects ?? []).compactMap(\.imageMediaRef))
        if let background = input.backgroundImage { references.insert(background.mediaRef) }
        guard references.count <= 16 else { throw MapSceneError.invalidSpec("A scene supports at most 16 custom image assets.") }
        let sources = try references.sorted().map { reference -> (MediaAsset, MediaAsset.PreparationContext) in
            guard let asset = mediaAssetsById[reference], asset.type == .image, !asset.isGenerating,
                  asset.generationStatus == .none else {
                throw MapSceneError.invalidSpec("Map image '\(reference)' must be a ready image in the media library.")
            }
            return (asset, asset.preparationContext)
        }
        func validate() throws {
            try Task.checkCancellation()
            try projectPackageCoordinator.validate(lease)
            guard projectURL?.standardizedFileURL.path == package.standardizedFileURL.path,
                  timeline.id == timelineId, timeline.fps == fps, timeline.width == width, timeline.height == height,
                  sources.allSatisfy({ mediaAssetsById[$0.0.id] === $0.0 && $0.0.preparationContext == $0.1 }) else {
                throw MapSceneError.invalidSpec("The project, timeline configuration, or a map image changed during rendering; retry the scene.")
            }
        }
        try validate()
        let atlas = try await MapAtlasStore.shared.snapshot()
        try validate()
        let spec = try await MapSceneSpec.resolve(input, defaultWidth: width, defaultHeight: height, defaultFPS: fps, atlas: atlas)
        try validate()
        let seconds = Double(spec.durationFrames) / Double(spec.fps)
        let placementFrames = addToTimeline ? try ClipPlacement.frames(seconds: seconds, fps: fps) : nil
        let assetId = UUID().uuidString
        func placement(for mediaRef: String) throws -> ClipPlacement.Clips? {
            guard let placementFrames else { return nil }
            return try ClipPlacement.make(source: .init(mediaRef: mediaRef, type: .video,
                durationSeconds: seconds, hasAudio: false, width: spec.width, height: spec.height),
                trackType: .video, fps: fps, canvasWidth: width, canvasHeight: height,
                startFrame: startFrame, durationFrames: placementFrames, addLinkedAudio: false)
        }
        _ = try placement(for: assetId)
        let candidates = mediaAssets.filter {
            $0.mapScene?.rendererVersion == MapSceneRenderer.version && $0.mapScene?.atlasVersion == atlas.version
                && $0.mapScene?.input.width == spec.width && $0.mapScene?.input.height == spec.height
                && $0.mapScene?.input.fps == spec.fps && $0.mapScene?.input.durationFrames == spec.durationFrames
                && $0.type == .video && $0.generationStatus == .none
        }
        let candidateURLs = Dictionary(candidates.compactMap { asset in asset.mapScene.map {
            ($0.digest, MapSceneReusableFile(url: asset.url, videoDigest: $0.videoDigest))
        } },
            uniquingKeysWith: { first, _ in first })
        let sourceURLs = Dictionary(uniqueKeysWithValues: sources.map { ($0.0.id, $0.1.sourceURL) })
        let output = try await render(spec, atlas, sourceURLs, candidateURLs)
        let record = MapSceneRecord(input: spec.authoredInput, digest: output.digest, atlasVersion: atlas.version,
            rendererVersion: MapSceneRenderer.version, imageDigests: output.imageDigests, videoDigest: output.videoDigest)

        if let stage = output.stage {
            let asset = MediaAsset(id: assetId, url: stage, type: .video,
                name: name ?? "Map \(output.digest.prefix(8))", duration: seconds)
            asset.sourceWidth = spec.width
            asset.sourceHeight = spec.height
            asset.sourceFPS = Double(spec.fps)
            asset.hasAudio = false
            asset.mapScene = record
            var clips: ClipPlacement.Clips?
            var clipId: String?
            // The installer owns cleanup even when cancellation occurred after rendering.
            _ = try await commitStagedProjectMedia(stage, filename: "map-\(UUID().uuidString).mov", lease: lease, validate: {
                try validate()
                clips = try placement(for: asset.id)
            }) { destination in
                asset.url = destination
                clipId = self.publishMapScene(asset, clips: clips, importing: true)
            }
            return .init(asset: asset, clipId: clipId, changed: true, reused: false, placementFrames: placementFrames)
        }
        try validate()
        guard let asset = candidates.first(where: { $0.mapScene?.digest == output.digest }),
              mediaAssetsById[asset.id] === asset, candidateURLs[output.digest]?.url == asset.url else {
            throw MapSceneError.invalidSpec("The reusable map asset changed or was removed; retry the scene.")
        }
        if !addToTimeline { return .init(asset: asset, clipId: nil, changed: false, reused: true, placementFrames: nil) }
        if let existing = timeline.tracks.flatMap(\.clips).first(where: {
            $0.mediaRef == asset.id && $0.startFrame == startFrame && $0.durationFrames == placementFrames && $0.trimStartFrame == 0
        }) {
            return .init(asset: asset, clipId: existing.id, changed: false, reused: true, placementFrames: placementFrames)
        }
        let clips = try placement(for: asset.id)
        let clipId = publishMapScene(asset, clips: clips, importing: false)
        return .init(asset: asset, clipId: clipId, changed: true, reused: true, placementFrames: placementFrames)
    }

    private func publishMapScene(_ asset: MediaAsset, clips: ClipPlacement.Clips?, importing: Bool) -> String? {
        let action = L10n.string("Build Map Scene")
        let before = mediaLibraryUndoSnapshot()
        undo.perform(action) {
            undo.withoutRegistration {
                if importing { importMediaAsset(asset) }
                if let clip = clips?.primary {
                    let index = timeline.tracks.firstIndex { track in
                        track.type == .video && !track.hidden && !track.clips.contains {
                            $0.startFrame < clip.endFrame && clip.startFrame < $0.endFrame
                        }
                    } ?? insertTrack(at: 0, type: .video)
                    timeline.tracks[index].clips.append(clip)
                    sortClips(trackIndex: index)
                }
            }
            undo.register(action, withTarget: self) { editor in
                editor.restoreMediaLibraryUndoSnapshot(before, actionName: action)
            }
            onProjectCheckpointRequired?()
        }
        if importing { searchIndex.schedule(asset) }
        prepareMediaVisuals(for: asset)
        if clips != nil { notifyTimelineChanged() }
        return clips?.primary.id
    }
}
