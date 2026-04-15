import AVFoundation
import AppKit
import CoreVideo

/// Generates a still-frame video from a static image for use in AVComposition pipelines.
/// Cached by (mediaRef, width, height) so repeated calls are free.
enum ImageVideoGenerator {

    private static let cacheDirectory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PalmierPro/ImageVideos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Generated a long enough video so it can be freely resized (2 frames at 1fps for 30 minutes — tiny file).
    private static let generatedDuration: Double = 1800

    /// Returns a cached or newly-generated still-frame .mov for the given image.
    static func stillVideo(
        for imageURL: URL,
        mediaRef: String,
        size: CGSize
    ) async throws -> URL {
        let duration = generatedDuration
        let filename = "\(mediaRef)_\(Int(size.width))x\(Int(size.height)).mov"
        let outputURL = cacheDirectory.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL
        }

        guard let nsImage = NSImage(contentsOf: imageURL) else {
            throw ImageVideoError.imageLoadFailed
        }

        let pixelBuffer = try createPixelBuffer(from: nsImage, size: size)
        try await writeStillVideo(pixelBuffer: pixelBuffer, to: outputURL, size: size, duration: duration)
        return outputURL
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

        // Fill black background, then draw image to fill the buffer at native size
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
        // Clean up any partial file from a previous failed attempt
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
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

        // Write two frames (start + end) — sufficient for AVComposition to represent the full duration
        let times: [CMTime] = [
            .zero,
            CMTime(value: CMTimeValue(ceil(duration)) - 1, timescale: 1),
        ]
        for time in times {
            while !adaptor.assetWriterInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }
            adaptor.append(pixelBuffer, withPresentationTime: time)
        }

        input.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw writer.error ?? ImageVideoError.writeFailed
        }
    }

    enum ImageVideoError: Error {
        case imageLoadFailed
        case pixelBufferCreationFailed
        case writeFailed
    }
}
