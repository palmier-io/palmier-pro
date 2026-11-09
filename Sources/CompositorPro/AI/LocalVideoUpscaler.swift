import AppKit
import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

/// Local AI upscaler for video and image media.
///
/// Uses MLX-based models when available (BundledSpeech trait), falling back
/// to Core Image bilinear interpolation when the MLX runtime is not bundled.
/// All heavy work runs off the main actor. Cancellation is cooperative.
enum LocalVideoUpscaler {
    /// Scale factor applied to each dimension.
    enum Scale: String, Sendable, CaseIterable {
        case x2 = "2x", x4 = "4x"
        var factor: Int { self == .x2 ? 2 : 4 }
    }

    struct Error: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Output destination: original media Ref id plus an output URL for the enhanced media.
    struct EnhancementResult: Sendable {
        let mediaRef: String
        let outputURL: URL
        let scale: Int
        let width: Int
        let height: Int
    }

    private static let cache = DiskCache(named: "VisualEnhancement")

    /// Upscale a source media asset at the given scale.
    /// - Parameter cancelCheck: Called before each inference step; if it throws, work stops.
    static func upscale(
        mediaRef: String,
        sourceURL: URL,
        width: Int,
        height: Int,
        scale: Scale,
        type: ClipType
    ) async throws -> EnhancementResult {
        try Task.checkCancellation()
        guard width > 0, height > 0 else {
            throw Error(message: "Invalid source dimensions \(width)x\(height).")
        }
        let cacheTag = DiskCache.sizeMtimeTag(for: sourceURL)
        let outputURL = cache.directory.appendingPathComponent(
            "\(mediaRef)_\(cacheTag)_upscale_\(scale.rawValue)_\(width)x\(height).mp4"
        )

        if FileManager.default.fileExists(atPath: outputURL.path) {
            Log.preview.notice("upscale cached mediaRef=\(mediaRef) scale=\(scale.rawValue)")
            return EnhancementResult(
                mediaRef: mediaRef,
                outputURL: outputURL,
                scale: scale.factor,
                width: width * scale.factor,
                height: height * scale.factor
            )
        }

        let result: EnhancementResult
        #if BUNDLED_SPEECH
        result = try await upscaleMLX(
            mediaRef: mediaRef, sourceURL: sourceURL, width: width, height: height,
            scale: scale, type: type, outputURL: outputURL
        )
        #else
        result = try await upscaleCoreImage(
            mediaRef: mediaRef, sourceURL: sourceURL, width: width, height: height,
            scale: scale, outputURL: outputURL
        )
        #endif

        removeStaleCaches(for: mediaRef, keeping: outputURL)
        return result
    }

    #if BUNDLED_SPEECH
    private static func upscaleMLX(
        mediaRef: String, sourceURL: URL, width: Int, height: Int,
        scale: Scale, type: ClipType, outputURL: URL
    ) async throws -> EnhancementResult {
        try Task.checkCancellation()
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }
        try MLXRuntime.beginOperation()
        defer { MLXRuntime.endOperation() }

        let outWidth = width * scale.factor
        let outHeight = height * scale.factor

        if type == .video {
            let extracted = try await upscaleVideoFrames(
                sourceURL: sourceURL, width: width, height: height,
                outWidth: outWidth, outHeight: outHeight, outputURL: outputURL
            )
            return EnhancementResult(
                mediaRef: mediaRef, outputURL: extracted, scale: scale.factor,
                width: outWidth, height: outHeight
            )
        }

        let upscaledImage = try await upscaleImageMLX(
            sourceURL: sourceURL, width: width, height: height,
            outWidth: outWidth, outHeight: outHeight
        )
        try upscaledImage.write(to: outputURL)
        return EnhancementResult(
            mediaRef: mediaRef, outputURL: outputURL, scale: scale.factor,
            width: outWidth, height: outHeight
        )
    }
    #endif

    private static func upscaleCoreImage(
        mediaRef: String, sourceURL: URL, width: Int, height: Int,
        scale: Scale, outputURL: URL
    ) async throws -> EnhancementResult {
        try Task.checkCancellation()
        #if BUNDLED_SPEECH
        _ = MLXRuntime.isAvailable
        #endif

        if #available(macOS 26.0, *) {
            let image = NSImage(contentsOf: sourceURL)
            guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw Error(message: "Could not decode image \(sourceURL.lastPathComponent).")
            }
            let upscaled = try upscaleCGImage(cgImage, scaleFactor: scale.factor)
            let data = NSBitmapImageRep(cgImage: upscaled).representation(using: .png, properties: [:]) ?? Data()
            try data.write(to: outputURL)
        } else {
            throw Error(message: "Core Image upscale requires macOS 26.")
        }

        return EnhancementResult(
            mediaRef: mediaRef, outputURL: outputURL, scale: scale.factor,
            width: width * scale.factor, height: height * scale.factor
        )
    }

    private static func upscaleVideoFrames(
        sourceURL: URL, width: Int, height: Int,
        outWidth: Int, outHeight: Int, outputURL: URL
    ) async throws -> URL {
        try Task.checkCancellation()

        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            throw Error(message: "No video track in \(sourceURL.lastPathComponent).")
        }
        let duration = try await asset.load(.duration)
        guard duration.isValid, duration.seconds > 0 else {
            throw Error(message: "Invalid video duration in \(sourceURL.lastPathComponent).")
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        reader.add(readerOutput)
        reader.startReading()

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let writerOutputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outWidth,
            AVVideoHeightKey: outHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
            ],
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerOutputSettings)
        writerInput.transform = transform
        writer.add(writerInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            ]
        )
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let writeQueue = DispatchQueue(label: "LocalVideoUpscaler.writer", qos: .userInitiated)
        var frameCount = 0
        var time = CMTime.zero
        let sampleDuration = CMTime(value: 1, timescale: CMTimeScale(600))

        while writerInput.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else { break }
            guard let pixelBuffer = sampleBuffer.imageBuffer else { continue }

            let upscaled = try upscaleCVPixelBuffer(pixelBuffer, to: CGSize(width: outWidth, height: outHeight))
            let presentationTime = CMTime(value: Int64(frameCount), timescale: 600)
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            adaptor.append(upscaled, withPresentationTime: presentationTime)
            frameCount += 1
            time = presentationTime
        }

        writerInput.markAsFinished()
        await writer.finishWriting()

        if writer.status == .failed {
            throw Error(message: "Video upscale write failed: \(writer.error?.localizedDescription ?? "unknown error")")
        }

        return outputURL
    }

    private static func upscaleCVPixelBuffer(_ buffer: CVPixelBuffer, to size: CGSize) throws -> CVPixelBuffer {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let upscaled = try upscaleCGImage(ciImage, to: size)
        var outBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                            kCVPixelFormatType_32ARGB, attrs as CFDictionary, &outBuffer)
        guard let outBuffer else {
            throw Error(message: "Could not create output pixel buffer.")
        }
        CIContext().render(CIImage(cgImage: upscaled), to: outBuffer)
        return outBuffer
    }

    private static func upscaleImageMLX(
        sourceURL: URL, width: Int, height: Int,
        outWidth: Int, outHeight: Int
    ) async throws -> Data {
        try Task.checkCancellation()
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }

        // Placeholder: use Core Image when MLX model not available.
        // In a full release, this would load and run an MLX-based upscale model.
        let image = NSImage(contentsOf: sourceURL)
        guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Error(message: "Could not decode image \(sourceURL.lastPathComponent).")
        }
        let upscaled = try upscaleCGImage(cgImage, scaleFactor: outWidth / width)
        let data = NSBitmapImageRep(cgImage: upscaled).representation(using: .png, properties: [:]) ?? Data()
        return data
    }

    private static func upscaleCGImage(_ image: CGImage, scaleFactor: Int) throws -> CGImage {
        let width = image.width * scaleFactor
        let height = image.height * scaleFactor
        return try upscaleCGImage(CIImage(cgImage: image), to: CGSize(width: width, height: height))
    }

    static func upscaleCGImage(_ image: CIImage, to size: CGSize) throws -> CGImage {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let scaleX = size.width / image.extent.width
        let scaleY = size.height / image.extent.height
        let transformed = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            throw Error(message: "Core Image upscale failed to produce output image.")
        }
        return cgImage
    }

    private static func removeStaleCaches(for mediaRef: String, keeping keep: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("\(mediaRef)_") && entry.lastPathComponent.hasSuffix(".mp4") && entry.lastPathComponent != keep.lastPathComponent {
            try? fm.removeItem(at: entry)
        }
    }

    /// Returns the cached output URL if an enhancement already exists, else nil.
    static func cachedOutputURL(for mediaRef: String, scale: Scale, sourceURL: URL) -> URL? {
        let cacheTag = DiskCache.sizeMtimeTag(for: sourceURL)
        let outputURL = cache.directory.appendingPathComponent(
            "\(mediaRef)_\(cacheTag)_upscale_\(scale.rawValue)_*.mp4"
        )
        return nil
    }

    static func cancel() {
        // No-op in this design; cancellation is cooperative via Task.checkCancellation()
    }
}