import AVFoundation
import AppKit
import CoreVideo

enum ImageVideoGenerator {

    private static let cacheDirectory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PalmierPro/ImageVideos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // Generates a long enough (30min) video so it can be freely resized
    private static let generatedDuration: Double = 1800

    // H.264 encoder paths are less reliable above 4096 px
    private static let maxEncoderDimension: CGFloat = 4096

    static func stillVideo(
        for imageURL: URL,
        mediaRef: String,
        size: CGSize
    ) async throws -> URL {
        let duration = generatedDuration
        let size = clampedForEncoder(size)
        let filename = "\(mediaRef)_\(Int(size.width))x\(Int(size.height)).mov"
        let outputURL = cacheDirectory.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL
        }

        do {
            guard let nsImage = NSImage(contentsOf: imageURL) else {
                throw ImageVideoError.imageLoadFailed
            }

            let pixelBuffer = try createPixelBuffer(from: nsImage, size: size)
            try await writeStillVideo(pixelBuffer: pixelBuffer, to: outputURL, size: size, duration: duration)
            return outputURL
        } catch {
            Log.preview.error("stillVideo failed file=\(imageURL.lastPathComponent) size=\(Int(size.width))x\(Int(size.height)): \(error.localizedDescription)")
            throw error
        }
    }

    private static func clampedForEncoder(_ size: CGSize) -> CGSize {
        let sourceWidth = max(1, size.width)
        let sourceHeight = max(1, size.height)
        let longest = max(sourceWidth, sourceHeight)
        let scale = longest > maxEncoderDimension ? maxEncoderDimension / longest : 1
        return CGSize(
            width: encoderDimension(sourceWidth * scale),
            height: encoderDimension(sourceHeight * scale)
        )
    }

    private static func encoderDimension(_ value: CGFloat) -> CGFloat {
        // Some H.264 encoder paths reject odd frame sizes.
        let pixels = Int(value.rounded(.down))
        return CGFloat(max(2, pixels - pixels % 2))
    }

    static func imageNativeSize(url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    // MARK: - Private

    private static func createPixelBuffer(from image: NSImage, size: CGSize) throws -> CVPixelBuffer {
        let width = Int(size.width)
        let height = Int(size.height)

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw ImageVideoError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            throw ImageVideoError.pixelBufferCreationFailed
        }

        context.setFillColor(.black)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageVideoError.imageLoadFailed
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return buffer
    }

    private static func writeStillVideo(
        pixelBuffer: CVPixelBuffer,
        to outputURL: URL,
        size: CGSize,
        duration: Double
    ) async throws {

        let tempURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".writing-" + outputURL.lastPathComponent)
        try? FileManager.default.removeItem(at: tempURL)

        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: nil
        )

        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? ImageVideoError.writeFailed
        }
        writer.startSession(atSourceTime: .zero)

        // Two frames span the full still-video duration without a long file.
        let times: [CMTime] = [
            .zero,
            CMTime(value: CMTimeValue(ceil(duration)) - 1, timescale: 1),
        ]
        for time in times {
            while !adaptor.assetWriterInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw writer.error ?? ImageVideoError.appendFailed(seconds: time.seconds)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw writer.error ?? ImageVideoError.writeFailed
        }

        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.moveItem(at: tempURL, to: outputURL)
    }

    enum ImageVideoError: LocalizedError {
        case imageLoadFailed
        case pixelBufferCreationFailed
        case appendFailed(seconds: Double)
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .imageLoadFailed:
                "could not load image"
            case .pixelBufferCreationFailed:
                "could not create pixel buffer"
            case .appendFailed(let seconds):
                "could not append still frame at \(String(format: "%.3f", seconds))s"
            case .writeFailed:
                "could not write still video"
            }
        }
    }
}
