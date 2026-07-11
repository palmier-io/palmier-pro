import AVFoundation
import Foundation

/// Downscales a video to fit within a target long-side bound. Used to keep reference videos
/// inside model size caps (e.g. Seedance's ~1112 px max long side).
enum VideoCompressor {
    struct CompressionError: LocalizedError {
        let reason: String
        var errorDescription: String? { "Video compression failed: \(reason)" }
    }

    /// Returns a temp URL with a downscaled copy when the source exceeds `maxLongSide`, else `nil`.
    static func compressIfNeeded(url: URL, maxLongSide: Int = 1100) async throws -> URL? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let display = size.applying(transform)
        let longSide = max(abs(display.width), abs(display.height))
        if longSide <= CGFloat(maxLongSide) { return nil }

        // 960x540 preset keeps long side at 960, safely under Seedance's ~1112 cap and
        // cuts file size. Scales down only; smaller sources (ruled out above) pass through.
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset960x540) else {
            throw CompressionError(reason: "export preset unsupported")
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ref-compressed-\(UUID().uuidString).mp4")

        Log.generation.notice("compress start url=\(url.lastPathComponent) longside=\(Int(longSide))")
        try await session.export(to: outputURL, as: .mp4)
        Log.generation.notice("compress ok url=\(outputURL.lastPathComponent)")
        return outputURL
    }
}
