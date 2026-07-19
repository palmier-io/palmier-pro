import AVFoundation
import Foundation

struct RenderedFrame: Sendable {
    let stagedURL: URL
    let width: Int
    let height: Int
    let actualSourceSeconds: Double?
}

enum FrameCaptureRenderer {
    private static let renderGate = AsyncSemaphore(value: 2)
    private static let mediaDurationReceiptTolerance = 0.001

    enum RenderError: LocalizedError {
        case noVideoTrack
        case invalidDuration
        case sourceTimeOutOfRange(requested: Double, duration: Double)
        case renderFailed(String)
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                "No video track is available."
            case .invalidDuration:
                "The video has no finite duration."
            case .sourceTimeOutOfRange(let requested, let duration):
                "Source time \(Self.formatted(requested))s is outside 0…\(Self.formatted(duration))s."
            case .renderFailed(let reason):
                "Could not render the frame: \(reason)"
            case .encodeFailed:
                "Could not encode the captured frame as PNG."
            }
        }

        private static func formatted(_ value: Double) -> String {
            String(format: "%.3f", value)
        }
    }

    @concurrent
    static func timeline(
        _ timeline: Timeline,
        frame: Int,
        mediaURLs: [String: URL],
        resolveTimeline: @escaping @Sendable (String) -> Timeline?,
        missingMediaRefs: Set<String>
    ) async throws -> RenderedFrame {
        try await renderGate.wait()
        defer { Task { await renderGate.signal() } }
        try Task.checkCancellation()

        let canvas = CGSize(width: timeline.width, height: timeline.height)
        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { mediaURLs[$0] },
            resolveTimeline: resolveTimeline,
            missingMediaRefs: missingMediaRefs,
            renderSize: canvas
        )
        guard (try? await result.composition.loadTracks(withMediaType: .video).first) != nil else {
            try Task.checkCancellation()
            throw RenderError.noVideoTrack
        }
        try Task.checkCancellation()

        let generator = AVAssetImageGenerator(asset: result.composition)
        generator.videoComposition = result.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = canvas
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(timeline.fps))
        let image = try await generateImage(using: generator, at: time).image
        return try stage(image, actualSourceSeconds: nil)
    }

    @concurrent
    static func media(url: URL, sourceSeconds: Double) async throws -> RenderedFrame {
        try await renderGate.wait()
        defer { Task { await renderGate.signal() } }
        try Task.checkCancellation()

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RenderError.noVideoTrack
        }
        let timeRange = try await track.load(.timeRange)
        let loadedMinimum = try? await track.load(.minFrameDuration)
        try Task.checkCancellation()
        let minimumFrameDuration = loadedMinimum.flatMap { duration in
            duration.isNumeric && duration > .zero ? duration : nil
        } ?? CMTime(value: 1, timescale: 600)
        let request = try sourceFrameRequest(
            sourceSeconds: sourceSeconds,
            timeRange: timeRange,
            minimumFrameDuration: minimumFrameDuration
        )

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = minimumFrameDuration
        generator.requestedTimeToleranceAfter = request.capturesLastFrame ? .zero : minimumFrameDuration

        let generated = try await generateImage(using: generator, at: request.time)
        return try stage(
            generated.image,
            actualSourceSeconds: SourceMediaTimebase.relativeSeconds(
                absoluteTime: generated.actualTime,
                trackStart: timeRange.start
            )
        )
    }

    static func sourceFrameRequest(
        sourceSeconds: Double,
        timeRange: CMTimeRange,
        minimumFrameDuration: CMTime
    ) throws -> (time: CMTime, capturesLastFrame: Bool) {
        let duration = timeRange.duration
        let durationSeconds = duration.seconds
        guard timeRange.isValid,
              timeRange.start.isNumeric,
              duration.isNumeric,
              durationSeconds.isFinite,
              durationSeconds > 0 else {
            throw RenderError.invalidDuration
        }
        guard sourceSeconds.isFinite,
              sourceSeconds >= 0,
              sourceSeconds <= durationSeconds + mediaDurationReceiptTolerance else {
            throw RenderError.sourceTimeOutOfRange(requested: sourceSeconds, duration: durationSeconds)
        }
        let capturesLastFrame = sourceSeconds >= durationSeconds - minimumFrameDuration.seconds
        let requestedTime = capturesLastFrame
            ? max(timeRange.start, timeRange.end - minimumFrameDuration)
            : SourceMediaTimebase.absoluteTime(
                relativeSeconds: sourceSeconds,
                trackStart: timeRange.start
            )
        return (requestedTime, capturesLastFrame)
    }

    @concurrent
    static func discardStagedFile(at url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }

    private static func generateImage(
        using generator: AVAssetImageGenerator,
        at time: CMTime
    ) async throws -> (image: CGImage, actualTime: CMTime) {
        do {
            let generated = try await generator.image(at: time)
            return (generated.image, generated.actualTime)
        } catch {
            try Task.checkCancellation()
            throw RenderError.renderFailed(error.localizedDescription)
        }
    }

    private nonisolated static func stage(
        _ image: CGImage,
        actualSourceSeconds: Double?
    ) throws -> RenderedFrame {
        guard let data = ImageEncoder.encodePNG(image) else { throw RenderError.encodeFailed }
        let stagedURL = try FileIO.stageData(data, pathExtension: "png")
        do {
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }
        return RenderedFrame(
            stagedURL: stagedURL,
            width: image.width,
            height: image.height,
            actualSourceSeconds: actualSourceSeconds
        )
    }
}
