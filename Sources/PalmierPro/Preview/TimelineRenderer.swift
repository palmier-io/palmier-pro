import AVFoundation
import Foundation

/// Renders a frame range of the timeline to a temp mp4
/// Caller owns the temp file.
enum TimelineRenderer {
    struct RenderError: LocalizedError {
        let reason: String
        var errorDescription: String? { "Could not render selection: \(reason)" }
    }

    /// Exports frames [startFrame, startFrame + frameCount) of timeline.
    @MainActor
    static func render(
        timeline: Timeline,
        resolver: MediaResolver,
        resolveTimeline: @escaping @Sendable (String) -> Timeline? = { _ in nil },
        missingMediaRefs: Set<String> = [],
        startFrame: Int,
        frameCount: Int,
        shortSide: Int? = nil,
        includeAudio: Bool = true,
        preset: String = AVAssetExportPresetMediumQuality
    ) async throws -> URL {
        guard timeline.fps > 0 else { throw RenderError(reason: "invalid fps") }
        guard frameCount > 0 else { throw RenderError(reason: "empty selection") }

        let canvas = CGSize(width: timeline.width, height: timeline.height)
        let renderSize = Self.renderSize(canvas: canvas, shortSide: shortSide)
        let mediaURLs = resolver.expectedURLMap()

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { mediaURLs[$0] },
            resolveTimeline: resolveTimeline,
            missingMediaRefs: missingMediaRefs,
            renderSize: renderSize
        )

        guard let session = AVAssetExportSession(asset: result.composition, presetName: preset) else {
            throw RenderError(reason: "export preset unsupported")
        }
        if includeAudio {
            session.audioMix = result.audioMix
        } else {
            for track in result.composition.tracks(withMediaType: .audio) {
                result.composition.removeTrack(track)
            }
        }

        session.videoComposition = result.videoComposition

        let timescale = CMTimeScale(timeline.fps)
        session.timeRange = CMTimeRange(
            start: CMTime(value: CMTimeValue(startFrame), timescale: timescale),
            duration: CMTime(value: CMTimeValue(frameCount), timescale: timescale)
        )

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-render-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        Log.generation.notice("timeline-render start frames=\(startFrame)..<\(startFrame + frameCount) fps=\(timeline.fps)")
        try await session.export(to: outputURL, as: .mp4)
        Log.generation.notice("timeline-render ok url=\(outputURL.lastPathComponent)")
        return outputURL
    }

    /// Render size for the given short side
    private static func renderSize(canvas: CGSize, shortSide: Int?) -> CGSize {
        guard let shortSide, canvas.width > 0, canvas.height > 0 else {
            return CGSize(width: even(canvas.width), height: even(canvas.height))
        }
        let canvasShort = min(canvas.width, canvas.height)
        let scale = min(1.0, Double(shortSide) / canvasShort)
        return CGSize(width: even(canvas.width * scale), height: even(canvas.height * scale))
    }

    private static func even(_ value: Double) -> Int { max(2, (Int(value.rounded()) / 2) * 2) }
}
