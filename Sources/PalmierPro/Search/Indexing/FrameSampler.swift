import AVFoundation
import CoreGraphics
import Foundation

/// Streams visually distinct frames for indexing: luma scene changes start new shots,
/// a coverage floor keeps long static shots represented.
enum FrameSampler {
    static let samplerVersion = 1

    struct Options {
        var candidateInterval: Double = 2.0
        var coverageFloor: Double = 8.0
        var promoteDiff: Float = 12
        var maxSize = CGSize(width: 512, height: 512)
        var highResEdge: CGFloat = 3000
    }

    struct Frame {
        let time: Double
        let image: CGImage
        let isNewShot: Bool
    }

    static func frames(url: URL, duration: Double, options: Options = Options()) -> AsyncThrowingStream<Frame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await sample(url: url, duration: duration, options: options) { frame in
                        continuation.yield(frame)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func sample(
        url: URL,
        duration: Double,
        options: Options,
        emit: (Frame) -> Void
    ) async throws {
        let asset = AVURLAsset(url: url)
        var interval = options.candidateInterval
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize),
           max(abs(size.width), abs(size.height)) >= options.highResEdge {
            interval *= 2
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = options.maxSize
        // ≥1s lets the decoder grab the nearest sync frame
        let tolerance = CMTime(seconds: max(interval / 2, 1.0), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard duration > 0 else { return }
        var seconds = Array(stride(from: interval / 2, to: duration, by: interval))
        if seconds.isEmpty { seconds = [duration / 2] }
        let times = seconds.map { CMTime(seconds: $0, preferredTimescale: 600) }

        var lastGrid: [Float]?
        var lastKeptTime = -Double.infinity
        var lastTime = -Double.infinity
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            guard case .success(_, let image, let actualTime) = result else { continue }
            let t = actualTime.seconds
            guard t > lastTime else { continue }
            lastTime = t
            guard let grid = LumaGrid.compute(image) else { continue }

            let isNewShot: Bool
            if let last = lastGrid {
                isNewShot = LumaGrid.meanDiff(grid, last) > options.promoteDiff
            } else {
                isNewShot = true
            }
            lastGrid = grid

            guard isNewShot || t - lastKeptTime >= options.coverageFloor else { continue }
            lastKeptTime = t
            emit(Frame(time: t, image: image, isNewShot: isNewShot))
        }
    }
}

/// Mean luma per cell of an 8×8 downsample — cheap visual-change fingerprint.
enum LumaGrid {
    static let cells = 8

    static func compute(_ image: CGImage) -> [Float]? {
        let n = cells
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(
            data: &pixels, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        return (0..<n * n).map { i in
            Float(pixels[i * 4]) * 0.299 + Float(pixels[i * 4 + 1]) * 0.587 + Float(pixels[i * 4 + 2]) * 0.114
        }
    }

    static func meanDiff(_ a: [Float], _ b: [Float]) -> Float {
        var diff: Float = 0
        for i in 0..<a.count { diff += abs(a[i] - b[i]) }
        return diff / Float(a.count)
    }
}
