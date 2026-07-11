import AVFoundation
import Foundation

/// Exports the visible range of a video clip to a temp mp4 file.
enum VideoTrimExtractor {
    struct ExtractionError: LocalizedError {
        let reason: String
        var errorDescription: String? { "Trim extraction failed: \(reason)" }
    }

    /// Returns a URL to a temp mp4 containing frames
    /// `[trimStartFrame, trimStartFrame + sourceFramesConsumed)` of `sourceURL`.
    /// Caller owns the temp file and should delete it once upload completes.
    static func extract(_ trim: TrimmedSource) async throws -> URL {
        guard trim.fps > 0 else {
            throw ExtractionError(reason: "invalid fps \(trim.fps)")
        }
        guard trim.sourceFramesConsumed > 0 else {
            throw ExtractionError(reason: "empty range")
        }

        let asset = AVURLAsset(url: trim.sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw ExtractionError(reason: "no video track in source")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExtractionError(reason: "could not create video track")
        }

        try compVideo.insertTimeRange(trim.timeRange, of: videoTrack, at: .zero)
        compVideo.preferredTransform = try await videoTrack.load(.preferredTransform)

        if let audioTrack = audioTracks.first,
           let compAudio = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? compAudio.insertTimeRange(trim.timeRange, of: audioTrack, at: .zero)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim-\(UUID().uuidString).mp4")

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExtractionError(reason: "export preset unsupported")
        }

        // Pin output fps — without this the composition's timescale
        // re-quantizes frame timings and exports a fractional rate
        let nominal = (try? await videoTrack.load(.nominalFrameRate)) ?? 0
        let targetFps: Int32 = nominal >= 24 && nominal <= 60
            ? Int32(Float(nominal).rounded())
            : 30
        let videoComposition = try await AVVideoComposition.videoComposition(
            withPropertiesOf: composition
        )
        var videoConfig = videoComposition.palmierConfiguration()
        videoConfig.frameDuration = CMTime(value: 1, timescale: targetFps)
        session.videoComposition = AVVideoComposition(configuration: videoConfig)

        Log.generation.notice("trim-extract start frames=\(trim.trimStartFrame)..<\(trim.trimStartFrame + trim.sourceFramesConsumed) timelineFps=\(trim.fps) sourceFps=\(nominal) outFps=\(targetFps)")
        try await session.export(to: outputURL, as: .mp4)
        Log.generation.notice("trim-extract ok url=\(outputURL.lastPathComponent)")
        return outputURL
    }
}
