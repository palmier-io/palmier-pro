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
            sourceId: assetId
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
        await installExtractedAudio(name: name, folderId: folderId, sourceId: clipId) { stagedURL in
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
        sourceId: String,
        produce: (URL) async throws -> Void
    ) async {
        guard (try? projectPackageCoordinator.beginMutation()) != nil else { return }
        let filename = Self.uniqueClipFilename(for: .audio)
        let mediaDir = projectURL?.appendingPathComponent(Project.mediaDirectoryName)
            ?? FileManager.default.temporaryDirectory
        let destURL = mediaDir.appendingPathComponent(filename)
        let placeholder = MediaAsset(url: destURL, type: .audio, name: name)
        placeholder.folderId = folderId
        placeholder.generationStatus = .generating
        importMediaAsset(placeholder)
        let stagedURL = FileIO.temporaryFileURL(pathExtension: "m4a")
        defer {
            try? FileManager.default.removeItem(at: stagedURL)
            projectPackageCoordinator.endMutation()
        }

        do {
            try await produce(stagedURL)
            guard mediaAssetsById[placeholder.id] != nil else { return }
            placeholder.url = try await commitStagedProjectMedia(
                stagedURL,
                filename: filename,
                workAlreadyAdmitted: true
            )
            placeholder.generationStatus = .none
            await finalizeImportedAsset(placeholder)
            Log.project.notice("extractAudio ok source=\(sourceId) out=\(placeholder.url.lastPathComponent)")
        } catch {
            placeholder.generationStatus = .failed(error.localizedDescription)
            updateManifestMetadata(for: [placeholder])
            Log.project.error("extractAudio failed source=\(sourceId): \(error.localizedDescription)")
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
        guard (try? projectPackageCoordinator.beginMutation()) != nil else { return }

        let filename = Self.uniqueClipFilename(for: clip.mediaType)
        let mediaDir = projectURL?.appendingPathComponent(Project.mediaDirectoryName) ?? FileManager.default.temporaryDirectory
        let destURL = mediaDir.appendingPathComponent(filename)

        let placeholder = MediaAsset(url: destURL, type: clip.mediaType, name: "\(sourceName) (clip)")
        placeholder.generationStatus = .generating
        importMediaAsset(placeholder)

        let fps = timeline.fps
        let trimStartFrame = clip.trimStartFrame
        let sourceFramesConsumed = clip.sourceFramesConsumed
        let durationFrames = clip.durationFrames
        let speed = clip.speed
        let mediaType = clip.mediaType

        Task { @MainActor in
            defer { self.projectPackageCoordinator.endMutation() }
            let stagedURL = FileIO.temporaryFileURL(pathExtension: mediaType == .video ? "mp4" : "m4a")
            defer { try? FileManager.default.removeItem(at: stagedURL) }
            do {
                try await Self.exportClipRange(
                    sourceURL: sourceURL,
                    destURL: stagedURL,
                    fps: fps,
                    trimStartFrame: trimStartFrame,
                    sourceFramesConsumed: sourceFramesConsumed,
                    durationFrames: durationFrames,
                    speed: speed,
                    mediaType: mediaType
                )
                placeholder.url = try await self.commitStagedProjectMedia(
                    stagedURL,
                    filename: filename,
                    workAlreadyAdmitted: true
                )
                placeholder.generationStatus = .none
                await self.finalizeImportedAsset(placeholder)
                Log.project.notice("saveClipAsMedia ok clip=\(clipId) out=\(placeholder.url.lastPathComponent)")
            } catch {
                placeholder.generationStatus = .failed(error.localizedDescription)
                self.updateManifestMetadata(for: [placeholder])
                Log.project.error("saveClipAsMedia failed clip=\(clipId): \(error.localizedDescription)")
            }
        }
    }

    /// Save the selected timeline range (all tracks composited) as a new video
    func saveTimelineRangeAsMedia() {
        guard let range = validSelectedTimelineRange else { return }
        let startFrame = range.startFrame
        let frameCount = range.endFrame - range.startFrame
        guard frameCount > 0 else { return }
        guard (try? projectPackageCoordinator.beginMutation()) != nil else { return }

        let filename = Self.uniqueClipFilename(for: .video)
        let mediaDir = projectURL?.appendingPathComponent(Project.mediaDirectoryName) ?? FileManager.default.temporaryDirectory
        let destURL = mediaDir.appendingPathComponent(filename)

        let placeholder = MediaAsset(url: destURL, type: .video, name: "Timeline range")
        placeholder.generationStatus = .rendering
        importMediaAsset(placeholder)

        let timeline = self.timeline
        let resolver = mediaResolver
        let missingMediaRefs = self.missingMediaRefs
        let resolveTimeline = timelineResolver()

        Task { @MainActor in
            defer { self.projectPackageCoordinator.endMutation() }
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
                placeholder.url = try await self.commitStagedProjectMedia(
                    tempURL,
                    filename: filename,
                    workAlreadyAdmitted: true
                )
                placeholder.generationStatus = .none
                await self.finalizeImportedAsset(placeholder)
                Log.project.notice("saveTimelineRangeAsMedia ok frames=\(startFrame)..<\(startFrame + frameCount) out=\(placeholder.url.lastPathComponent)")
            } catch {
                placeholder.generationStatus = .failed(error.localizedDescription)
                self.updateManifestMetadata(for: [placeholder])
                Log.project.error("saveTimelineRangeAsMedia failed: \(error.localizedDescription)")
            }
        }
    }

    private static func uniqueClipFilename(for type: ClipType) -> String {
        let ext = type == .video ? "mp4" : "m4a"
        return "clip-\(UUID().uuidString.prefix(8)).\(ext)"
    }

    private static func exportClipRange(
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

        try? FileManager.default.removeItem(at: destURL)

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
