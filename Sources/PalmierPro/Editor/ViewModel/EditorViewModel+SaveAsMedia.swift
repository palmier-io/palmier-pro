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

        let mediaDir: URL
        if let projectURL {
            mediaDir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
            try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        } else {
            mediaDir = FileManager.default.temporaryDirectory
        }
        let destURL = mediaDir.appendingPathComponent(Self.uniqueClipFilename(for: clip.mediaType))

        let placeholder = MediaAsset(url: destURL, type: clip.mediaType, name: "\(sourceName) (clip)")
        placeholder.generationStatus = .generating
        importMediaAsset(placeholder)

        let fps = timeline.fps
        let trimStartFrame = clip.trimStartFrame
        let sourceFramesConsumed = clip.sourceFramesConsumed
        let durationFrames = clip.durationFrames
        let speed = clip.speed
        let mediaType = clip.mediaType

        Task { @MainActor [weak self] in
            do {
                try await Self.exportClipRange(
                    sourceURL: sourceURL,
                    destURL: destURL,
                    fps: fps,
                    trimStartFrame: trimStartFrame,
                    sourceFramesConsumed: sourceFramesConsumed,
                    durationFrames: durationFrames,
                    speed: speed,
                    mediaType: mediaType
                )
                placeholder.generationStatus = .none
                await self?.finalizeImportedAsset(placeholder)
                Log.project.notice("saveClipAsMedia ok clip=\(clipId) out=\(destURL.lastPathComponent)")
            } catch {
                placeholder.generationStatus = .failed(error.localizedDescription)
                Log.project.error("saveClipAsMedia failed clip=\(clipId): \(error.localizedDescription)")
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
