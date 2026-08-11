import AVFoundation
import Foundation

enum AudioTrackExtractor {
    struct ExtractionError: LocalizedError {
        let reason: String
        var errorDescription: String? { "Audio extraction failed: \(reason)" }
    }

    static func extract(
        sourceURL: URL,
        trimmedSource: TrimmedSource? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ExtractionError(reason: "source has no audio track")
        }

        let assetDuration = try await asset.load(.duration)
        let sourceRange = trimmedSource?.timeRange
            ?? CMTimeRange(start: .zero, duration: assetDuration)

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExtractionError(reason: "could not create audio track")
        }
        try compositionTrack.insertTimeRange(sourceRange, of: audioTrack, at: .zero)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-\(UUID().uuidString).m4a")
        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ExtractionError(reason: "M4A export is unavailable")
        }
        try await session.export(to: outputURL, as: .m4a)
        return outputURL
    }
}
