import AVFoundation
import Foundation

/// Converts a mask track's RLE data into a grayscale matte video and saves it to a file.
enum MatteVideoRenderer {
    enum RenderError: LocalizedError {
        case writerSetup
        case appendFailed
        case invalidFrame(Int)

        var errorDescription: String? {
            switch self {
            case .writerSetup: "Could not create matte video writer."
            case .appendFailed: "Could not write matte video frame."
            case .invalidFrame(let index): "Matte frame \(index) was invalid."
            }
        }
    }

    @concurrent
    static func render(
        payload: MaskTrackPayload,
        width: Int,
        height: Int,
        fps: Double,
        to destinationURL: URL
    ) async throws {
        guard width > 0, height > 0, fps > 0, !payload.rle.isEmpty else {
            throw RenderError.writerSetup
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destinationURL)

        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mov)
        let timescale = Int32(max(1, fps.rounded()))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: 1.0,
                AVVideoExpectedSourceFrameRateKey: timescale,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoMaxKeyFrameIntervalKey: max(1, timescale / 2),
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        guard writer.canAdd(input) else { throw RenderError.writerSetup }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RenderError.writerSetup }
        writer.startSession(atSourceTime: .zero)

        do {
            for (index, frame) in payload.rle.enumerated() {
                try Task.checkCancellation()
                let runs: [MaskRLE.Run]
                do {
                    runs = try MaskRLE.runs(from: frame, width: width, height: height)
                } catch {
                    throw RenderError.invalidFrame(index)
                }
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    if writer.status == .failed { throw writer.error ?? RenderError.appendFailed }
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard let pool = adaptor.pixelBufferPool else { throw RenderError.writerSetup }
                var buffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                      let buffer else { throw RenderError.writerSetup }
                fill(buffer, width: width, height: height, runs: runs)
                let time = CMTime(value: CMTimeValue(index), timescale: timescale)
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw writer.error ?? RenderError.appendFailed
                }
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(
            value: CMTimeValue(payload.rle.count),
            timescale: timescale
        ))
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw writer.error ?? RenderError.appendFailed
        }
    }

    /// Fills mask pixels white, others black (opaque alpha). Uses pattern fills for speed.
    private static func fill(_ buffer: CVPixelBuffer, width: Int, height: Int, runs: [MaskRLE.Run]) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        var blackOpaque: UInt32 = 0xFF00_0000  // BGRA little-endian: B=0 G=0 R=0 A=255
        var white: UInt32 = 0xFFFF_FFFF
        for row in 0..<height {
            memset_pattern4(base.advanced(by: row * bytesPerRow), &blackOpaque, width * 4)
        }
        for run in runs {
            // Each run is a continuous range of pixels; split at row boundaries for correct memory layout.
            var pixel = run.start
            let runEnd = run.start + run.length
            while pixel < runEnd {
                let row = pixel / width
                let column = pixel % width
                let count = min(runEnd - pixel, width - column)
                memset_pattern4(
                    base.advanced(by: row * bytesPerRow + column * 4),
                    &white,
                    count * 4
                )
                pixel += count
            }
        }
    }
}
