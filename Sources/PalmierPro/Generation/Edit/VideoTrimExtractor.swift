import AVFoundation
import Foundation

/// Describes a clip's visible source range so an AI action can upload just
/// that portion instead of the full source media.
struct TrimmedSource: Sendable {
    let sourceURL: URL
    let trimStartFrame: Int
    let trimEndFrame: Int
    let sourceFramesConsumed: Int
    let fps: Int

    var hasTrim: Bool { trimStartFrame > 0 || trimEndFrame > 0 }
    var durationSeconds: Double { Double(sourceFramesConsumed) / Double(max(1, fps)) }
}

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

        let timescale = CMTimeScale(trim.fps)
        let sourceStart = CMTime(value: CMTimeValue(trim.trimStartFrame), timescale: timescale)
        let sourceDuration = CMTime(value: CMTimeValue(trim.sourceFramesConsumed), timescale: timescale)
        let sourceRange = CMTimeRange(start: sourceStart, duration: sourceDuration)

        try compVideo.insertTimeRange(sourceRange, of: videoTrack, at: .zero)
        compVideo.preferredTransform = try await videoTrack.load(.preferredTransform)

        if let audioTrack = audioTracks.first,
           let compAudio = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? compAudio.insertTimeRange(sourceRange, of: audioTrack, at: .zero)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim-\(UUID().uuidString).mp4")

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExtractionError(reason: "export preset unsupported")
        }

        Log.generation.notice("trim-extract start frames=\(trim.trimStartFrame)..<\(trim.trimStartFrame + trim.sourceFramesConsumed) fps=\(trim.fps)")
        try await session.export(to: outputURL, as: .mp4)
        Log.generation.notice("trim-extract ok url=\(outputURL.lastPathComponent)")
        return outputURL
    }
}
