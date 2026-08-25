import AVFoundation
import CoreVideo
import Foundation

struct DetectedShot: Codable, Sendable, Equatable {
    var startSeconds: Double
    var durationSeconds: Double
    /// Mean inter-frame difference inside the shot, normalized 0–1.
    var motionScore: Double

    var endSeconds: Double { startSeconds + durationSeconds }
    var motionEnergy: MotionEnergy { MotionEnergyEstimator.bucket(forScore: motionScore) }
}

enum MotionEnergyEstimator {
    static func bucket(forScore score: Double) -> MotionEnergy {
        switch score {
        case ..<0.02: .still
        case ..<0.06: .gentle
        case ..<0.14: .dynamic
        default: .whip
        }
    }

    static func suggestedSpeed(for shot: DetectedShot) -> Double? {
        switch shot.motionEnergy {
        case .whip where shot.durationSeconds < 1.0: 2.0
        case .still where shot.durationSeconds > 4.0: 0.5
        default: nil
        }
    }
}

/// Detects shot boundaries by decoding downscaled frames and scoring luma-histogram
/// plus mean-pixel differences against an adaptive threshold.
enum SceneCutDetector {
    enum DetectError: Error {
        case noVideoTrack
        case readFailed(String)
    }

    private static let analysisWidth = 120
    private static let sampleFPS = 8.0
    private static let minimumShotSeconds = 0.35
    private static let histogramBins = 32
    private static let cancellationStride = 24

    @concurrent
    static func detectShots(
        in sourceURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [DetectedShot] {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw DetectError.noVideoTrack
        }
        let timeRange = try await track.load(.timeRange)
        let naturalSize = try await track.load(.naturalSize)
        let durationSeconds = timeRange.duration.seconds
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw DetectError.readFailed("Source has zero or indefinite duration.")
        }

        let samples = try frameSamples(
            asset: asset,
            track: track,
            timeRange: timeRange,
            naturalSize: naturalSize,
            durationSeconds: durationSeconds,
            progress: progress
        )
        return shots(from: samples, durationSeconds: durationSeconds)
    }

    // MARK: - Decoding

    private struct FrameFeatures {
        var histogram: [Double]
        var meanLuma: Double
    }

    private struct FrameSample {
        var seconds: Double
        var score: Double
    }

    private static func frameSamples(
        asset: AVURLAsset,
        track: AVAssetTrack,
        timeRange: CMTimeRange,
        naturalSize: CGSize,
        durationSeconds: Double,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> [FrameSample] {
        let aspect = naturalSize.width > 0 ? Double(naturalSize.height) / Double(naturalSize.width) : 1
        let analysisHeight = max(2, Int((Double(analysisWidth) * aspect).rounded()))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: analysisWidth,
            kCVPixelBufferHeightKey as String: analysisHeight,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw DetectError.readFailed("Cannot configure video reader.") }
        reader.add(output)
        guard reader.startReading() else {
            throw DetectError.readFailed(reader.error?.localizedDescription ?? "Reader failed to start.")
        }
        defer { reader.cancelReading() }

        let sampleInterval = 1.0 / sampleFPS
        var samples: [FrameSample] = []
        var previous: FrameFeatures?
        var lastSampledSeconds = -Double.infinity
        var framesSinceCancellationCheck = 0

        while let buffer = output.copyNextSampleBuffer() {
            framesSinceCancellationCheck += 1
            if framesSinceCancellationCheck >= cancellationStride {
                framesSinceCancellationCheck = 0
                try Task.checkCancellation()
            }
            let seconds = CMSampleBufferGetPresentationTimeStamp(buffer).seconds - timeRange.start.seconds
            guard seconds - lastSampledSeconds >= sampleInterval,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { continue }
            lastSampledSeconds = seconds

            let features = frameFeatures(from: pixelBuffer)
            if let previous {
                samples.append(FrameSample(seconds: seconds, score: difference(previous, features)))
            }
            previous = features
            progress?(min(1, seconds / durationSeconds))
        }
        if reader.status == .failed {
            throw DetectError.readFailed(reader.error?.localizedDescription ?? "Video decode failed.")
        }
        try Task.checkCancellation()
        return samples
    }

    private static func frameFeatures(from pixelBuffer: CVPixelBuffer) -> FrameFeatures {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        var histogram = [Double](repeating: 0, count: histogramBins)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return FrameFeatures(histogram: histogram, meanLuma: 0)
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        var lumaSum = 0.0
        var count = 0
        for y in 0..<height {
            let row = bytes + y * bytesPerRow
            for x in 0..<width {
                let pixel = row + x * 4
                // BGRA integer luma approximation: (b + 2g + r) / 4.
                let luma = (Int(pixel[0]) + (Int(pixel[1]) << 1) + Int(pixel[2])) >> 2
                histogram[min(histogramBins - 1, luma * histogramBins / 256)] += 1
                lumaSum += Double(luma)
                count += 1
            }
        }
        guard count > 0 else { return FrameFeatures(histogram: histogram, meanLuma: 0) }
        let total = Double(count)
        for bin in histogram.indices { histogram[bin] /= total }
        return FrameFeatures(histogram: histogram, meanLuma: lumaSum / total / 255.0)
    }

    private static func difference(_ a: FrameFeatures, _ b: FrameFeatures) -> Double {
        var histogramDistance = 0.0
        for bin in a.histogram.indices {
            histogramDistance += abs(a.histogram[bin] - b.histogram[bin])
        }
        return (histogramDistance / 2.0) * 0.75 + abs(a.meanLuma - b.meanLuma) * 0.25
    }

    // MARK: - Boundary extraction

    private static func shots(from samples: [FrameSample], durationSeconds: Double) -> [DetectedShot] {
        guard !samples.isEmpty else {
            return [DetectedShot(startSeconds: 0, durationSeconds: durationSeconds, motionScore: 0)]
        }

        let scores = samples.map(\.score)
        let mean = scores.reduce(0, +) / Double(scores.count)
        let variance = scores.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(scores.count)
        let threshold = max(0.18, mean + 3.5 * variance.squareRoot())

        var cutSeconds: [Double] = []
        for sample in samples where sample.score >= threshold {
            guard sample.seconds >= minimumShotSeconds,
                  durationSeconds - sample.seconds >= minimumShotSeconds,
                  sample.seconds - (cutSeconds.last ?? -.infinity) >= minimumShotSeconds else { continue }
            cutSeconds.append(sample.seconds)
        }

        let boundaries = ([0.0] + cutSeconds + [durationSeconds]).sorted()
        var shots: [DetectedShot] = []
        for index in 0..<(boundaries.count - 1) {
            let start = boundaries[index]
            let end = boundaries[index + 1]
            guard end > start else { continue }
            let inShot = samples.filter { $0.seconds >= start && $0.seconds < end && $0.score < threshold }
            let motion = inShot.isEmpty ? 0 : inShot.map(\.score).reduce(0, +) / Double(inShot.count)
            shots.append(DetectedShot(startSeconds: start, durationSeconds: end - start, motionScore: motion))
        }
        guard shots.isEmpty else { return shots }
        return [DetectedShot(startSeconds: 0, durationSeconds: durationSeconds, motionScore: mean)]
    }
}
