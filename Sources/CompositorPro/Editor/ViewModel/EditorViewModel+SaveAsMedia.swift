import AppKit
import AVFoundation

extension EditorViewModel {

    func canExtractAudio(from asset: MediaAsset) -> Bool {
        asset.type == .video && asset.hasAudio && !asset.isGenerating && !isMediaOffline(asset.id)
    }

    func extractAudio(from assetIds: [String]) async {
        for id in assetIds {
            await extractAudio(from: id)
        }
    }

    func extractAudio(from assetId: String) async {
        guard let asset = mediaAssetsById[assetId] else { return }
        guard canExtractAudio(from: asset) else { return }
        guard let sourceURL = mediaResolver.resolveURL(for: asset.id) else {
            Log.project.error("extractAudio: source missing for asset=\(assetId)")
            return
        }
        await installExtractedAudio(
            name: "\(asset.name) (audio)",
            folderId: asset.folderId,
            validateSource: {
                guard self.mediaAssetsById[assetId] === asset, self.canExtractAudio(from: asset),
                      self.mediaResolver.expectedURL(for: assetId) == sourceURL else { throw CancellationError() }
            }
        ) { destURL in
            _ = try await AudioTrackExtractor.extract(sourceURL: sourceURL, destURL: destURL)
        }
    }

    func canExtractAudio(fromClipId clipId: String) -> Bool {
        audioClipForExtraction(clipId: clipId) != nil
    }

    func extractAudio(fromClipId clipId: String) async {
        guard let clip = audioClipForExtraction(clipId: clipId) else { return }
        guard let sourceURL = mediaResolver.resolveURL(for: clip.mediaRef) else {
            Log.project.error("extractAudio: source missing for clip=\(clipId)")
            return
        }
        let name = "\(mediaResolver.displayName(for: clip.mediaRef)) (audio)"
        let folderId = mediaAssetsById[clip.mediaRef]?.folderId
        let fps = timeline.fps
        let trimStartFrame = clip.trimStartFrame
        let sourceFramesConsumed = clip.sourceFramesConsumed
        let durationFrames = clip.durationFrames
        let speed = clip.speed
        await installExtractedAudio(name: name, folderId: folderId, validateSource: {
            guard self.audioClipForExtraction(clipId: clipId) == clip, self.timeline.fps == fps,
                  self.mediaResolver.expectedURL(for: clip.mediaRef) == sourceURL else { throw CancellationError() }
        }) { stagedURL in
            try await Self.exportClipRange(
                sourceURL: sourceURL,
                destURL: stagedURL,
                fps: fps,
                trimStartFrame: trimStartFrame,
                sourceFramesConsumed: sourceFramesConsumed,
                durationFrames: durationFrames,
                speed: speed,
                mediaType: .audio
            )
        }
    }

    private func audioClipForExtraction(clipId: String) -> Clip? {
        guard let clip = clipFor(id: clipId) else { return nil }
        guard clip.sourceClipType != .sequence, clip.multicamGroupId == nil else { return nil }
        let partners = linkedPartnerIds(of: clip.id).compactMap { clipFor(id: $0) }
        if clip.mediaType == .video {
            if let audio = partners.first(where: { $0.mediaType == .audio }) {
                return isExtractableClip(audio) ? audio : nil
            }
            guard let asset = mediaAssetsById[clip.mediaRef], canExtractAudio(from: asset) else { return nil }
            return isExtractableClip(clip) ? clip : nil
        }
        if clip.mediaType == .audio, partners.contains(where: { $0.mediaType == .video }) {
            return isExtractableClip(clip) ? clip : nil
        }
        return nil
    }

    private func isExtractableClip(_ clip: Clip) -> Bool {
        !isClipMediaOffline(clip) && !isClipMediaGenerating(clip)
    }

    private func installExtractedAudio(
        name: String,
        folderId: String?,
        validateSource: @MainActor () throws -> Void,
        produce: (URL) async throws -> Void
    ) async {
        do {
            try await projectPackageCoordinator.withMutation { lease in
                guard let package = self.projectURL else { throw CocoaError(.fileNoSuchFile) }
                try validateSource()
                let filename = Self.uniqueClipFilename(for: .audio)
                let placeholder = MediaAsset(url: package.appendingPathComponent("media/\(filename)"), type: .audio, name: name)
                placeholder.folderId = folderId
                placeholder.generationStatus = .generating
                self.importMediaAsset(placeholder)
                do {
                    let staged = try await self.stageExtractedMedia(pathExtension: "m4a", produce: produce)
                    _ = try await self.commitStagedProjectMedia(staged, filename: filename, lease: lease, validate: {
                        try validateSource()
                        guard self.mediaAssetsById[placeholder.id] === placeholder else { throw CancellationError() }
                    }) { destination in
                        placeholder.url = destination
                        self.updateManifestMetadata(for: [placeholder])
                    }
                    await self.finalizeImportedAsset(placeholder)
                } catch {
                    self.failExtractedMedia(placeholder, error: error)
                }
            }
        } catch {
            reportMediaImportFailure(error)
        }
    }

    /// Save a clip's visible source range (trim + speed baked in) as a new MediaAsset
    /// in the panel. Video and audio only
    func saveClipAsMedia(clipId: String) {
        guard let clip = clipFor(id: clipId) else { return }
        guard clip.mediaType == .video || clip.mediaType == .audio else { return }
        guard let sourceURL = mediaResolver.resolveURL(for: clip.mediaRef) else {
            Log.project.error("saveClipAsMedia: source missing for clip=\(clipId)")
            return
        }
        let sourceName = mediaResolver.displayName(for: clip.mediaRef)
        let filename = Self.uniqueClipFilename(for: clip.mediaType)

        let fps = timeline.fps
        let trimStartFrame = clip.trimStartFrame
        let sourceFramesConsumed = clip.sourceFramesConsumed
        let durationFrames = clip.durationFrames
        let speed = clip.speed
        let mediaType = clip.mediaType

        projectPackageCoordinator.startMutation { lease in
            guard let package = self.projectURL else { throw CocoaError(.fileNoSuchFile) }
            guard self.clipFor(id: clipId) == clip, self.timeline.fps == fps,
                  self.mediaResolver.expectedURL(for: clip.mediaRef) == sourceURL else { throw CancellationError() }
            let placeholder = MediaAsset(url: package.appendingPathComponent("media/\(filename)"), type: mediaType, name: "\(sourceName) (clip)")
            placeholder.generationStatus = .generating
            self.importMediaAsset(placeholder)
            do {
                let staged = try await self.stageExtractedMedia(pathExtension: mediaType == .video ? "mp4" : "m4a") { stagedURL in
                    try await Self.exportClipRange(sourceURL: sourceURL, destURL: stagedURL, fps: fps,
                        trimStartFrame: trimStartFrame, sourceFramesConsumed: sourceFramesConsumed,
                        durationFrames: durationFrames, speed: speed, mediaType: mediaType)
                }
                _ = try await self.commitStagedProjectMedia(staged, filename: filename, lease: lease, validate: {
                    guard self.mediaAssetsById[placeholder.id] === placeholder,
                          self.clipFor(id: clipId) == clip,
                          self.timeline.fps == fps,
                          self.mediaResolver.expectedURL(for: clip.mediaRef) == sourceURL else { throw CancellationError() }
                }) { destination in
                    placeholder.url = destination
                    self.updateManifestMetadata(for: [placeholder])
                }
                await self.finalizeImportedAsset(placeholder)
            } catch {
                self.failExtractedMedia(placeholder, error: error)
            }
        } onFailure: { error in
            if !(error is CancellationError) { self.reportMediaImportFailure(error) }
        }
    }

    /// Save the selected timeline range (all tracks composited) as a new video
    func saveTimelineRangeAsMedia() {
        guard let range = validSelectedTimelineRange else { return }
        let startFrame = range.startFrame
        let frameCount = range.endFrame - range.startFrame
        guard frameCount > 0 else { return }
        let filename = Self.uniqueClipFilename(for: .video)

        let timeline = self.timeline
        let resolver = mediaResolver
        let missingMediaRefs = self.missingMediaRefs
        let resolveTimeline = timelineResolver()
        let revision = timelineRenderRevision

        projectPackageCoordinator.startMutation { lease in
            guard let package = self.projectURL else { throw CocoaError(.fileNoSuchFile) }
            guard self.timeline == timeline, self.timelineRenderRevision == revision else { throw CancellationError() }
            let placeholder = MediaAsset(url: package.appendingPathComponent("media/\(filename)"), type: .video, name: "Timeline range")
            placeholder.generationStatus = .rendering
            self.importMediaAsset(placeholder)
            do {
                let tempURL = try await TimelineRenderer.render(
                    timeline: timeline,
                    resolver: resolver,
                    resolveTimeline: resolveTimeline,
                    missingMediaRefs: missingMediaRefs,
                    startFrame: startFrame,
                    frameCount: frameCount,
                    preset: AVAssetExportPresetHighestQuality
                )
                _ = try await self.commitStagedProjectMedia(tempURL, filename: filename, lease: lease, validate: {
                    guard self.mediaAssetsById[placeholder.id] === placeholder,
                          self.timeline == timeline, self.timelineRenderRevision == revision else { throw CancellationError() }
                }) { destination in
                    placeholder.url = destination
                    self.updateManifestMetadata(for: [placeholder])
                }
                await self.finalizeImportedAsset(placeholder)
            } catch {
                self.failExtractedMedia(placeholder, error: error)
            }
        } onFailure: { error in
            if !(error is CancellationError) { self.reportMediaImportFailure(error) }
        }
    }

    private func stageExtractedMedia(pathExtension: String, produce: (URL) async throws -> Void) async throws -> URL {
        let io = projectPackageCoordinator.io
        let staged = try await io.perform { FileIO.temporaryFileURL(pathExtension: pathExtension) }
        do {
            try Task.checkCancellation()
            try await produce(staged)
            return staged
        } catch {
            do { try await io.remove([staged]) }
            catch let cleanup { throw ProjectPackageCleanupError(operationError: error, cleanupError: cleanup) }
            throw error
        }
    }

    private func failExtractedMedia(_ asset: MediaAsset, error: Error) {
        guard mediaAssetsById[asset.id] === asset, !projectPackageCoordinator.isClosed else { return }
        asset.generationStatus = .failed(error.localizedDescription)
        updateManifestMetadata(for: [asset])
        onProjectCheckpointRequired?()
        reportMediaImportFailure(error)
    }

    private static func uniqueClipFilename(for type: ClipType) -> String {
        let ext = type == .video ? "mp4" : "m4a"
        return "clip-\(UUID().uuidString).\(ext)"
    }

    @concurrent private static func exportClipRange(
        sourceURL: URL,
        destURL: URL,
        fps: Int,
        trimStartFrame: Int,
        sourceFramesConsumed: Int,
        durationFrames: Int,
        speed: Double,
        mediaType: ClipType
    ) async throws {
        struct ExportError: LocalizedError {
            let reason: String
            var errorDescription: String? { reason }
        }

        let asset = AVURLAsset(url: sourceURL)
        let primaryType: AVMediaType = mediaType == .audio ? .audio : .video
        guard let primarySource = try await asset.loadTracks(withMediaType: primaryType).first else {
            throw ExportError(reason: "no \(primaryType.rawValue) track in source")
        }

        let composition = AVMutableComposition()
        guard let primaryComp = composition.addMutableTrack(
            withMediaType: primaryType,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError(reason: "could not create composition track")
        }

        let timescale = CMTimeScale(max(1, fps))
        let sourceFrames = max(1, sourceFramesConsumed)
        let timelineFrames = max(1, durationFrames)
        let trimStart = CMTime(value: CMTimeValue(trimStartFrame), timescale: timescale)
        let sourceDuration = CMTime(value: CMTimeValue(sourceFrames), timescale: timescale)
        let timelineDuration = CMTime(value: CMTimeValue(timelineFrames), timescale: timescale)
        let sourceRange = CMTimeRange(start: trimStart, duration: sourceDuration)

        try primaryComp.insertTimeRange(sourceRange, of: primarySource, at: .zero)
        if mediaType == .video {
            primaryComp.preferredTransform = try await primarySource.load(.preferredTransform)
        }
        if speed != 1.0 {
            primaryComp.scaleTimeRange(
                CMTimeRange(start: .zero, duration: sourceDuration),
                toDuration: timelineDuration
            )
        }

        if mediaType == .video,
           let audioSource = try? await asset.loadTracks(withMediaType: .audio).first,
           let audioComp = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? audioComp.insertTimeRange(sourceRange, of: audioSource, at: .zero)
            if speed != 1.0 {
                audioComp.scaleTimeRange(
                    CMTimeRange(start: .zero, duration: sourceDuration),
                    toDuration: timelineDuration
                )
            }
        }

        let presetName = mediaType == .audio
            ? AVAssetExportPresetAppleM4A
            : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: composition, presetName: presetName) else {
            throw ExportError(reason: "export preset unsupported")
        }
        let outType: AVFileType = mediaType == .audio ? .m4a : .mp4
        try await session.export(to: destURL, as: outType)
    }
}
