import AVFoundation
import Foundation

enum VideoPreprocessor {
    struct CompressionError: LocalizedError {
        let reason: String
        var errorDescription: String? { "Video compression failed: \(reason)" }
    }

    static func downscaleIfNeeded(url: URL, maxLongSide: Int = 1100) async throws -> URL? {
        try await exportIfNeeded(
            url: url, maxLongSide: CGFloat(maxLongSide), maxShortSide: nil,
            preset: AVAssetExportPreset960x540, requiredEncoding: nil
        )
    }

    static func transcodeIfNeeded(
        url: URL,
        maxResolution: SourceVideoResolution?,
        requiredEncoding: SourceVideoEncoding?
    ) async throws -> URL? {
        guard let maxResolution else {
            return try await exportIfNeeded(
                url: url, maxLongSide: nil, maxShortSide: nil,
                preset: AVAssetExportPresetHighestQuality,
                requiredEncoding: requiredEncoding
            )
        }
        let limits: (long: CGFloat, short: CGFloat, preset: String) = switch maxResolution {
        case .p720: (1280, 720, AVAssetExportPreset1280x720)
        case .p1080: (1920, 1080, AVAssetExportPreset1920x1080)
        case .p4k: (3840, 2160, AVAssetExportPreset3840x2160)
        }
        return try await exportIfNeeded(
            url: url, maxLongSide: limits.long, maxShortSide: limits.short,
            preset: limits.preset, requiredEncoding: requiredEncoding
        )
    }

    @concurrent
    private static func exportIfNeeded(
        url: URL,
        maxLongSide: CGFloat?,
        maxShortSide: CGFloat?,
        preset: String,
        requiredEncoding: SourceVideoEncoding?
    ) async throws -> URL? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let display = size.applying(transform)
        let longSide = max(abs(display.width), abs(display.height))
        let shortSide = min(abs(display.width), abs(display.height))
        let exceedsResolution = maxLongSide.map { longSide > $0 } == true
            || maxShortSide.map { shortSide > $0 } == true
        let requiresEncoding = switch requiredEncoding {
        case .h264MP4:
            try await !isH264MP4(url: url, track: track)
        case nil:
            false
        }
        guard exceedsResolution || requiresEncoding else { return nil }

        let exportPreset = exceedsResolution ? preset : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: exportPreset) else {
            throw CompressionError(reason: "export preset unsupported")
        }
        if exceedsResolution, let maxLongSide {
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
        }
        let outputURL = FileIO.temporaryFileURL(pathExtension: "mp4")
        do {
            try await session.export(to: outputURL, as: .mp4)
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func isH264MP4(url: URL, track: AVAssetTrack) async throws -> Bool {
        guard url.pathExtension.lowercased() == "mp4" else { return false }
        let descriptions = try await track.load(.formatDescriptions)
        return !descriptions.isEmpty && descriptions.allSatisfy {
            CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264
        }
    }
}
