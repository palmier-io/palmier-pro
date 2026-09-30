import AVFoundation
import AppKit
import CoreVideo
import Lottie

/// Bakes a Lottie animation to an alpha ProRes 4444 .mov
enum LottieVideoGenerator {

    static let cache = DiskCache(named: "LottieVideos")
    static var cacheDirectory: URL { cache.directory }

    private static let maxEncoderDimension: CGFloat = 4096

    /// Final frame is held out to here so a clip can be extended past the animation (freeze-frame).
    private static let holdTailSeconds: Double = 1800
    private static let jsonSniffByteLimit = 256 * 1024
    private static let jsonSignatureKeys = ["layers", "v", "w", "h", "op"]

    struct Metadata {
        let size: CGSize
        let framerate: Double
        let frameCount: Int
        let duration: TimeInterval
    }

    /// A `.json` must carry the Bodymovin comp signature; a `.lottie` must be a zip archive.
    static func isLottie(at url: URL) -> Bool {
        if url.pathExtension.lowercased() == "lottie" {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            return (try? handle.read(upToCount: 4)) == Data([0x50, 0x4B, 0x03, 0x04])
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: jsonSniffByteLimit),
              let first = data.first(where: { !isJSONWhitespace($0) }),
              first == UInt8(ascii: "{")
        else { return false }
        let text = String(decoding: data, as: UTF8.self)
        return jsonSignatureKeys.allSatisfy { containsJSONKey($0, in: text) }
    }

    private static func containsJSONKey(_ key: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        return text.range(of: #""\#(escaped)"\s*:"#, options: .regularExpression) != nil
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func metadata(for animation: LottieAnimation) -> Metadata {
        Metadata(
            size: animation.size,
            framerate: animation.framerate,
            frameCount: max(1, Int((animation.endFrame - animation.startFrame).rounded())),
            duration: animation.duration
        )
    }

    /// Metadata + first-frame thumbnail (native aspect) for the media library.
    @MainActor
    static func inspect(fileAt url: URL, maxThumbnail: CGFloat = 512) async throws -> (meta: Metadata, thumbnail: CGImage?) {
        let view = try await loadView(forFileAt: url, target: CGSize(width: maxThumbnail, height: maxThumbnail))
        guard let animation = view.animation else { throw LottieVideoError.invalidAnimation }
        let meta = metadata(for: animation)
        let target = clampedForEncoder(fit(meta.size, longestSide: maxThumbnail))
        relayout(view, target: target)
        var thumbnail: CGImage?
        if let context = makeContext(size: target, data: nil) {
            render(view: view, frame: animation.startFrame, into: context, target: target)
            thumbnail = context.makeImage()
        }
        return (meta, thumbnail)
    }

    @MainActor
    static func lottieVideo(for url: URL, mediaRef: String, size: CGSize) async throws -> URL {
        let target = clampedForEncoder(size)
        let filename = "\(mediaRef)_\(Int(target.width))x\(Int(target.height)).mov"
        let outputURL = cacheDirectory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: outputURL.path) { return outputURL }

        let view = try await loadView(forFileAt: url, target: target)
        guard let animation = view.animation else { throw LottieVideoError.invalidAnimation }
        let meta = metadata(for: animation)
        do {
            try await writeVideo(view: view, animation: animation, meta: meta, target: target, to: outputURL)
            return outputURL
        } catch {
            Log.preview.error("lottieVideo failed file=\(url.lastPathComponent) size=\(Int(target.width))x\(Int(target.height)): \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Loading

    /// Loads a plain `.json` or a zipped `.lottie` into a laid-out, render-ready view. A Lottie only
    /// scales to its frame via the view's layout; the bare layer renders at native scale.
    @MainActor
    static func loadView(forFileAt url: URL, target: CGSize) async throws -> LottieAnimationView {
        let config = LottieConfiguration(renderingEngine: .mainThread)
        let view: LottieAnimationView
        if url.pathExtension.lowercased() == "lottie" {
            let dotLottie = try await DotLottieFile.loadedFrom(filepath: url.path)
            view = LottieAnimationView(dotLottie: dotLottie, configuration: config)
        } else {
            let animation = try LottieAnimation.from(data: try Data(contentsOf: url))
            view = LottieAnimationView(animation: animation, configuration: config)
        }
        view.contentMode = .scaleToFill
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = nil
        relayout(view, target: target)
        return view
    }

    @MainActor
    static func renderFrame(view: LottieAnimationView, frame: AnimationFrameTime, target: CGSize) -> CGImage? {
        guard let context = makeContext(size: target, data: nil) else { return nil }
        render(view: view, frame: frame, into: context, target: target)
        return context.makeImage()
    }

    /// Renders `count` frames evenly spaced across the animation
    @MainActor
    static func sampleFrames(fileAt url: URL, count: Int, maxDimension: CGFloat = 512) async throws -> (meta: Metadata, frames: [(frameIndex: Int, image: CGImage)]) {
        let view = try await loadView(forFileAt: url, target: CGSize(width: maxDimension, height: maxDimension))
        guard let animation = view.animation else { throw LottieVideoError.invalidAnimation }
        let meta = metadata(for: animation)
        let target = clampedForEncoder(fit(meta.size, longestSide: maxDimension))
        relayout(view, target: target)

        let n = max(1, min(count, meta.frameCount))
        var frames: [(frameIndex: Int, image: CGImage)] = []
        for i in 0..<n {
            let frac = n == 1 ? 0 : Double(i) / Double(n - 1)
            let index = Int((Double(meta.frameCount - 1) * frac).rounded())
            if let image = renderFrame(view: view, frame: animation.startFrame + AnimationFrameTime(index), target: target) {
                frames.append((index, image))
            }
        }
        return (meta, frames)
    }

    // MARK: - Private

    @MainActor
    private static func relayout(_ view: LottieAnimationView, target: CGSize) {
        view.frame = CGRect(origin: .zero, size: target)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    /// The view already applied the contentMode scale; we only flip the bottom-left CG context to top-left.
    @MainActor
    private static func render(view: LottieAnimationView, frame: AnimationFrameTime, into context: CGContext, target: CGSize) {
        view.currentFrame = frame
        view.forceDisplayUpdate()
        context.clear(CGRect(origin: .zero, size: target))
        context.saveGState()
        context.translateBy(x: 0, y: target.height)
        context.scaleBy(x: 1, y: -1)
        view.layer?.render(in: context)
        context.restoreGState()
    }

    private static func makeContext(size: CGSize, data: UnsafeMutableRawPointer?, bytesPerRow: Int = 0) -> CGContext? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: data,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    @MainActor
    private static func writeVideo(
        view: LottieAnimationView,
        animation: LottieAnimation,
        meta: Metadata,
        target: CGSize,
        to outputURL: URL
    ) async throws {
        let fm = FileManager.default
        let parentDir = outputURL.deletingLastPathComponent()
        try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let tempURL = parentDir.appendingPathComponent(".writing-\(UUID().uuidString).mov")
        defer { try? fm.removeItem(at: tempURL) }

        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: Int(target.width),
            AVVideoHeightKey: Int(target.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(target.width),
                kCVPixelBufferHeightKey as String: Int(target.height),
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? LottieVideoError.writeFailed }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw LottieVideoError.writeFailed }

        let fps = max(1, meta.framerate)
        // Animation frames, then the final frame held far out so the clip can be extended (freeze-frame).
        var schedule = (0..<meta.frameCount).map { (frame: $0, seconds: Double($0) / fps) }
        schedule.append((frame: meta.frameCount - 1, seconds: max(holdTailSeconds, meta.duration + 1)))

        for (frame, seconds) in schedule {
            var bufferOut: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &bufferOut) == kCVReturnSuccess,
                  let buffer = bufferOut else { throw LottieVideoError.pixelBufferCreationFailed }
            try renderIntoBuffer(view: view, frame: animation.startFrame + AnimationFrameTime(frame), buffer: buffer, target: target)

            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard adaptor.append(buffer, withPresentationTime: CMTimeMakeWithSeconds(seconds, preferredTimescale: 600)) else {
                throw writer.error ?? LottieVideoError.appendFailed(frame: frame)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? LottieVideoError.writeFailed }

        guard !fm.fileExists(atPath: outputURL.path) else { return }
        do {
            try fm.moveItem(at: tempURL, to: outputURL)
        } catch {
            guard fm.fileExists(atPath: outputURL.path) else { throw error }
        }
    }

    @MainActor
    private static func renderIntoBuffer(view: LottieAnimationView, frame: AnimationFrameTime, buffer: CVPixelBuffer, target: CGSize) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = makeContext(
            size: target,
            data: CVPixelBufferGetBaseAddress(buffer),
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer)
        ) else { throw LottieVideoError.pixelBufferCreationFailed }
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)

        render(view: view, frame: frame, into: context, target: target)
    }

    private static func fit(_ size: CGSize, longestSide: CGFloat) -> CGSize {
        let longest = Swift.max(size.width, size.height)
        guard longest > longestSide, longest > 0 else { return size }
        let scale = longestSide / longest
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private static func clampedForEncoder(_ size: CGSize) -> CGSize {
        let w = Swift.max(1, size.width), h = Swift.max(1, size.height)
        let longest = Swift.max(w, h)
        let scale = longest > maxEncoderDimension ? maxEncoderDimension / longest : 1
        return CGSize(width: even(w * scale), height: even(h * scale))
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        let pixels = Int(value.rounded(.down))
        return CGFloat(Swift.max(2, pixels - pixels % 2))
    }

    enum LottieVideoError: LocalizedError {
        case invalidAnimation
        case writeFailed
        case pixelBufferCreationFailed
        case appendFailed(frame: Int)

        var errorDescription: String? {
            switch self {
            case .invalidAnimation: "could not read a Lottie animation from the file"
            case .writeFailed: "could not write lottie video"
            case .pixelBufferCreationFailed: "could not create pixel buffer"
            case .appendFailed(let frame): "could not append lottie frame \(frame)"
            }
        }
    }
}
