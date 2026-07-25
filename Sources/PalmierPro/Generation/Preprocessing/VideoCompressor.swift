import AVFoundation
import Foundation

enum VideoCompressor {
    struct CompressionError: LocalizedError {
        let reason: String
        var errorDescription: String? { "Video compression failed: \(reason)" }
    }

    static func compressIfNeeded(url: URL, maxLongSide: Int = 1100) async throws -> URL? {
        try await compressIfNeeded(
            url: url, maxLongSide: CGFloat(maxLongSide), maxShortSide: nil,
            preset: AVAssetExportPreset960x540
        )
    }

    static func compressIfNeeded(url: URL, maxResolution: SourceVideoResolution) async throws -> URL? {
        let limits: (long: CGFloat, short: CGFloat, preset: String) = switch maxResolution {
        case .p720: (1280, 720, AVAssetExportPreset1280x720)
        case .p1080: (1920, 1080, AVAssetExportPreset1920x1080)
        case .p4k: (3840, 2160, AVAssetExportPreset3840x2160)
        }
        return try await compressIfNeeded(
            url: url, maxLongSide: limits.long, maxShortSide: limits.short, preset: limits.preset)
    }

    @concurrent
    private static func compressIfNeeded(
        url: URL,
        maxLongSide: CGFloat,
        maxShortSide: CGFloat?,
        preset: String
    ) async throws -> URL? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let display = size.applying(transform)
        let longSide = max(abs(display.width), abs(display.height))
        let shortSide = min(abs(display.width), abs(display.height))
        guard longSide > maxLongSide
                || maxShortSide.map({ shortSide > $0 }) == true else { return nil }

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw CompressionError(reason: "export preset unsupported")
        }
        let scale = min(maxLongSide / longSide, (maxShortSide ?? maxLongSide) / shortSide)
        let renderSize = CGSize(
            width: max(2, floor(abs(display.width) * scale / 2) * 2),
            height: max(2, floor(abs(display.height) * scale / 2) * 2)
        )
        var layerConfig = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        layerConfig.setTransform(
            transform.concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
        let layer = AVVideoCompositionLayerInstruction(configuration: layerConfig)
        let instructionConfig = AVVideoCompositionInstruction.Configuration(
            backgroundColor: nil,
            enablePostProcessing: false,
            layerInstructions: [layer],
            requiredSourceSampleDataTrackIDs: [],
            timeRange: CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        )
        let instruction = AVVideoCompositionInstruction(configuration: instructionConfig)
        var compositionConfig = try await AVVideoComposition.Configuration(
            for: asset,
            prototypeInstruction: instruction
        )
        compositionConfig.renderSize = renderSize
        compositionConfig.instructions = [instruction]
        session.videoComposition = AVVideoComposition(configuration: compositionConfig)
        let outputURL = FileIO.temporaryFileURL(pathExtension: "mp4")
        do {
            try await session.export(to: outputURL, as: .mp4)
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
}
