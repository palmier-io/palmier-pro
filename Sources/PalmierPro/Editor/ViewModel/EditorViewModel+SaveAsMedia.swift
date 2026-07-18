import AppKit
import AVFoundation

extension EditorViewModel {

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
                    clip: clip,
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
        clip: Clip,
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
        try await insertRetimedRange(clip: clip, source: primarySource, into: primaryComp, timescale: timescale)
        if mediaType == .video {
            primaryComp.preferredTransform = try await primarySource.load(.preferredTransform)
        }

        if mediaType == .video,
           let audioSource = try? await asset.loadTracks(withMediaType: .audio).first,
           let audioComp = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? await insertRetimedRange(clip: clip, source: audioSource, into: audioComp, timescale: timescale)
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

    private static func insertRetimedRange(
        clip: Clip,
        source: AVAssetTrack,
        into compositionTrack: AVMutableCompositionTrack,
        timescale: CMTimeScale
    ) async throws {
        let sourceTimescale = (try? await source.load(.naturalTimeScale)) ?? timescale
        if let speedRamp = clip.speedRamp {
            let offsets = speedRamp.timelineOffsetsForRendering(duration: clip.durationFrames)
            for (startOffset, endOffset) in zip(offsets, offsets.dropFirst()) where endOffset > startOffset {
                let sourceStartFrames = Double(clip.trimStartFrame)
                    + clip.sourceOffset(atTimelineOffset: Double(startOffset))
                let sourceEndFrames = Double(clip.trimStartFrame)
                    + clip.sourceOffset(atTimelineOffset: Double(endOffset))
                let sourceStart = CMTime(
                    seconds: sourceStartFrames / Double(timescale),
                    preferredTimescale: sourceTimescale
                )
                let sourceDuration = CMTime(
                    seconds: (sourceEndFrames - sourceStartFrames) / Double(timescale),
                    preferredTimescale: sourceTimescale
                )
                let targetStart = CMTime(value: CMTimeValue(startOffset), timescale: timescale)
                let targetDuration = CMTime(value: CMTimeValue(endOffset - startOffset), timescale: timescale)
                try compositionTrack.insertTimeRange(
                    CMTimeRange(start: sourceStart, duration: sourceDuration),
                    of: source,
                    at: targetStart
                )
                compositionTrack.scaleTimeRange(
                    CMTimeRange(start: targetStart, duration: sourceDuration),
                    toDuration: targetDuration
                )
            }
            return
        }

        let sourceFrames = max(1, clip.sourceFramesConsumed)
        let timelineFrames = max(1, clip.durationFrames)
        let trimStart = CMTime(value: CMTimeValue(clip.trimStartFrame), timescale: timescale)
        let sourceDuration = CMTime(value: CMTimeValue(sourceFrames), timescale: timescale)
        try compositionTrack.insertTimeRange(
            CMTimeRange(start: trimStart, duration: sourceDuration),
            of: source,
            at: .zero
        )
        if clip.speed != 1 {
            compositionTrack.scaleTimeRange(
                CMTimeRange(start: .zero, duration: sourceDuration),
                toDuration: CMTime(value: CMTimeValue(timelineFrames), timescale: timescale)
            )
        }
    }
}
