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
        try await renderSnapshot(
            timeline: timeline, mediaURLs: resolver.expectedURLMap(), resolveTimeline: resolveTimeline,
            missingMediaRefs: missingMediaRefs, startFrame: startFrame, frameCount: frameCount,
            shortSide: shortSide, includeAudio: includeAudio, preset: preset
        )
    }

    @concurrent
    private static func renderSnapshot(
        timeline: Timeline, mediaURLs: [String: URL], resolveTimeline: @escaping @Sendable (String) -> Timeline?,
        missingMediaRefs: Set<String>, startFrame: Int, frameCount: Int, shortSide: Int?, includeAudio: Bool, preset: String
    ) async throws -> URL {
        guard (1...120).contains(timeline.fps) else { throw RenderError(reason: "invalid fps") }
        guard startFrame >= 0, frameCount > 0, startFrame <= timeline.totalFrames,
              frameCount <= timeline.totalFrames - startFrame else { throw RenderError(reason: "invalid selection range") }
        guard shortSide == nil || (2...4096).contains(shortSide!) else { throw RenderError(reason: "invalid render size") }
        try Task.checkCancellation()

        let canvas = CGSize(width: timeline.width, height: timeline.height)
        let renderSize = Self.renderSize(canvas: canvas, shortSide: shortSide)
        var renderTimeline = timeline
        if !includeAudio { renderTimeline.tracks.removeAll { $0.type == .audio } }
        let result = try await CompositionBuilder.build(
            timeline: renderTimeline,
            resolveURL: { mediaURLs[$0] },
            resolveTimeline: resolveTimeline,
            missingMediaRefs: missingMediaRefs,
            renderSize: renderSize
        )
        guard result.offlineMediaRefs.isEmpty, result.unprocessableMediaRefs.isEmpty else {
            throw RenderError(reason: "timeline contains missing or unreadable media")
        }

        guard let session = AVAssetExportSession(asset: result.composition, presetName: preset) else {
            throw RenderError(reason: "export preset unsupported")
        }
        if includeAudio {
            session.audioMix = result.audioMix
        }

        session.videoComposition = result.videoComposition

        let timescale = CMTimeScale(timeline.fps)
        session.timeRange = CMTimeRange(
            start: CMTime(value: CMTimeValue(startFrame), timescale: timescale),
            duration: CMTime(value: CMTimeValue(frameCount), timescale: timescale)
        )

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-render-\(UUID().uuidString).mp4")
        Log.generation.notice("timeline-render start frames=\(startFrame)..<\(startFrame + frameCount) fps=\(timeline.fps)")
        do {
            try await session.export(to: outputURL, as: .mp4)
            try Task.checkCancellation()
            try AudioGainTap.validate(result.audioMix)
        } catch {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                do { try FileManager.default.removeItem(at: outputURL) }
                catch { Log.export.warning("temporary render cleanup failed: \(error.localizedDescription)") }
            }
            throw error
        }
        Log.generation.notice("timeline-render ok url=\(outputURL.lastPathComponent)")
        return outputURL
    }

    @concurrent
    static func removeTemporaryRender(_ url: URL) async {
        do { try FileManager.default.removeItem(at: url) }
        catch { Log.export.warning("temporary render cleanup failed: \(error.localizedDescription)") }
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
