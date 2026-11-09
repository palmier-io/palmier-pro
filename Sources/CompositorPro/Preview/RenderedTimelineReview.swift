import AVFoundation
import Foundation

struct RenderedTimelineReview: Sendable {
    let durationSeconds: Double
    let frames: [Int]
    let images: [Data]
    let loudness: LoudnessMeasurement?
    let peakDBFS: Double?
    let clippedSamples: Int64

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
        try Task.checkCancellation()
        return RenderedTimelineReview(durationSeconds: duration, frames: frames, images: images, loudness: loudness,
                                      peakDBFS: peak > 0 ? 20 * log10(Double(peak)) : nil, clippedSamples: clipped)
    }
}
