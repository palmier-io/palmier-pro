import AVFoundation
import CoreGraphics
import Foundation

struct RenderedTimelineReview: Sendable {
    let durationSeconds: Double
    let frames: [Int]
    let images: [Data]
    let loudness: LoudnessMeasurement?
    let peakDBFS: Double?
    let clippedSamples: Int64
    /// Mean absolute luma difference between consecutive dense samples, and the sampled frame
    /// count. A near-zero value across a range is a frozen/static span; the numbers describe
    /// measured motion only and never certify intent or quality.
    let motion: MotionSummary

    @concurrent
    static func inspect(url: URL, frameCount: Int, fps: Int) async throws -> RenderedTimelineReview {
        guard (1...120).contains(fps), frameCount > 0, frameCount <= 60 * fps else {
            throw TimelineRenderer.RenderError(reason: "invalid review range")
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, abs(duration - Double(frameCount) / Double(fps)) <= 1 / Double(fps) else {
            throw TimelineRenderer.RenderError(reason: "encoded duration does not match selection")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let count = min(6, frameCount)
        let frames = (0..<count).map { count == 1 ? 0 : $0 * (frameCount - 1) / (count - 1) }
        var images: [Data] = []
        for frame in frames {
            try Task.checkCancellation()
            let image = try await generator.image(at: CMTime(value: Int64(frame), timescale: Int32(fps))).image
            guard let jpeg = ImageEncoder.encodeJPEG(image, quality: 0.8) else {
                throw TimelineRenderer.RenderError(reason: "review image encoding failed")
            }
            images.append(jpeg)
        }
        var loudness: LoudnessMeasurement?
        var peak: Float = 0
        var clipped: Int64 = 0
        if try await !asset.loadTracks(withMediaType: .audio).isEmpty {
            loudness = try await LoudnessAnalyzer.integratedLoudness(for: url, mediaRef: url.lastPathComponent)
            try await AudioTrackReader.read(from: url, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true,
                AVLinearPCMIsBigEndianKey: false,
            ]) { buffer in
                guard let channels = buffer.floatChannelData else { throw LoudnessMeter.MeasurementError.unsupportedFormat }
                for channel in 0..<Int(buffer.format.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) {
                        let sample = abs(channels[channel][frame])
                        guard sample.isFinite else { throw LoudnessMeter.MeasurementError.invalidSample }
                        peak = max(peak, sample)
                        if sample >= 1 { clipped += 1 }
                    }
                }
            }
        }
        let motion = try await sampleMotion(asset: asset, frameCount: frameCount, fps: fps)
        try Task.checkCancellation()
        return RenderedTimelineReview(durationSeconds: duration, frames: frames, images: images, loudness: loudness,
                                      peakDBFS: peak > 0 ? 20 * log10(Double(peak)) : nil, clippedSamples: clipped,
                                      motion: motion)
    }

    struct MotionSummary: Sendable, Equatable {
        var sampledFrames: Int
        var meanDelta: Double
        var minDelta: Double
        var maxDelta: Double
        var frozenSpans: [Int]
    }

    /// Samples up to 24 evenly spaced frames and measures mean absolute luma change between
    /// consecutive samples. Bounded work: draws each frame into a small RGBA buffer.
    private static func sampleMotion(asset: AVURLAsset, frameCount: Int, fps: Int) async throws -> MotionSummary {
        let sampleCount = min(24, frameCount)
        guard sampleCount >= 2 else {
            return MotionSummary(sampledFrames: sampleCount, meanDelta: 0, minDelta: 0, maxDelta: 0, frozenSpans: [])
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 64, height: 36)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let times = (0..<sampleCount).map { frameCount == 1 ? 0 : $0 * (frameCount - 1) / (sampleCount - 1) }

        var frames: [[UInt8]] = []
        for frame in times {
            try Task.checkCancellation()
            let cgImage = try await generator.image(at: CMTime(value: Int64(frame), timescale: Int32(fps))).image
            guard let luma = Self.lumaPlane(cgImage) else { continue }
            frames.append(luma)
        }
        guard frames.count >= 2 else {
            return MotionSummary(sampledFrames: frames.count, meanDelta: 0, minDelta: 0, maxDelta: 0, frozenSpans: [])
        }
        var deltas: [Double] = []
        for i in 1..<frames.count {
            let a = frames[i - 1], b = frames[i]
            let count = min(a.count, b.count)
            guard count > 0 else { continue }
            var sum = 0
            for j in 0..<count { sum += abs(Int(a[j]) - Int(b[j])) }
            deltas.append(Double(sum) / Double(count) / 255.0)
        }
        guard !deltas.isEmpty else {
            return MotionSummary(sampledFrames: frames.count, meanDelta: 0, minDelta: 0, maxDelta: 0, frozenSpans: [])
        }
        let frozen = deltas.enumerated().filter { $0.element < 0.002 }.map(\.offset)
        return MotionSummary(
            sampledFrames: frames.count,
            meanDelta: deltas.reduce(0, +) / Double(deltas.count),
            minDelta: deltas.min() ?? 0,
            maxDelta: deltas.max() ?? 0,
            frozenSpans: frozen
        )
    }

    /// Draws a frame into a fixed RGBA8 buffer and returns one luma byte per pixel.
    private static func lumaPlane(_ image: CGImage) -> [UInt8]? {
        let width = min(image.width, 64)
        let height = min(image.height, 36)
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var luma = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let o = i * 4
            let r = Int(buffer[o]), g = Int(buffer[o + 1]), b = Int(buffer[o + 2])
            luma[i] = UInt8(min(255, (r * 299 + g * 587 + b * 114) / 1000))
        }
        return luma
    }
}
