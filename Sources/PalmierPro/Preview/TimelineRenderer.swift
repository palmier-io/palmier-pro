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

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { resolver.resolveURL(for: $0) },
            renderSize: renderSize
        )
        if !includeAudio {
            for track in result.composition.tracks(withMediaType: .audio) {
                result.composition.removeTrack(track)
            }
        }

        let timescale = CMTimeScale(timeline.fps)
        let range = CMTimeRange(
            start: CMTime(value: CMTimeValue(startFrame), timescale: timescale),
            duration: CMTime(value: CMTimeValue(frameCount), timescale: timescale)
        )
        let endFrame = startFrame + frameCount
        let hasText = timeline.tracks.contains { t in
            t.clips.contains { $0.mediaType == .text && $0.startFrame < endFrame && $0.endFrame > startFrame }
        }
        let needsColor = CompositionBuilder.needsColorCompositor(timeline)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-render-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        Log.generation.notice("timeline-render start frames=\(startFrame)..<\(endFrame) fps=\(timeline.fps) text=\(hasText) color=\(needsColor)")

        if hasText && needsColor {
            // Same constraint as export: the Core Animation text tool can't share a pass
            // with the custom colour compositor. Bake colour over the range, then overlay text.
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("timeline-render-color-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: temp) }

            let colorSession = try makeSession(asset: result.composition, audioMix: includeAudio ? result.audioMix : nil, preset: preset)
            colorSession.videoComposition = result.videoComposition
            colorSession.timeRange = range
            try await colorSession.export(to: temp, as: .mp4)

            // Text rebased to the range (temp starts at frame 0).
            let rebased = Self.rebased(timeline, by: startFrame)
            let textSession = try await makeTextOverlaySession(inputURL: temp, timeline: rebased, fps: timeline.fps, renderSize: renderSize, preset: preset)
            try await textSession.export(to: outputURL, as: .mp4)
        } else {
            let session = try makeSession(asset: result.composition, audioMix: includeAudio ? result.audioMix : nil, preset: preset)
            var config = result.videoCompositionConfiguration
            if hasText {
                let (parent, videoLayer) = TextLayerController.buildForExport(timeline: timeline, fps: timeline.fps, renderSize: renderSize)
                config.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
            }
            session.videoComposition = AVVideoComposition(configuration: config)
            session.timeRange = range
            try await session.export(to: outputURL, as: .mp4)
        }

        Log.generation.notice("timeline-render ok url=\(outputURL.lastPathComponent)")
        return outputURL
    }

    private static func makeSession(asset: AVAsset, audioMix: AVMutableAudioMix?, preset: String) throws -> AVAssetExportSession {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw RenderError(reason: "export preset unsupported")
        }
        session.audioMix = audioMix
        return session
    }

    /// Second pass: overlay text onto an already-rendered (colour-baked) clip.
    @MainActor
    private static func makeTextOverlaySession(inputURL: URL, timeline: Timeline, fps: Int, renderSize: CGSize, preset: String) async throws -> AVAssetExportSession {
        let asset = AVURLAsset(url: inputURL)
        let session = try makeSession(asset: asset, audioMix: nil, preset: preset)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw RenderError(reason: "intermediate has no video track")
        }
        let duration = try await asset.load(.duration)
        let (parent, videoLayer) = TextLayerController.buildForExport(timeline: timeline, fps: fps, renderSize: renderSize)

        var cfg = AVVideoComposition.Configuration()
        cfg.renderSize = renderSize
        cfg.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        var instr = AVVideoCompositionInstruction.Configuration()
        instr.timeRange = CMTimeRange(start: .zero, duration: duration)
        instr.layerInstructions = [AVVideoCompositionLayerInstruction(configuration: .init(trackID: videoTrack.trackID))]
        cfg.instructions = [AVVideoCompositionInstruction(configuration: instr)]
        cfg.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
        session.videoComposition = AVVideoComposition(configuration: cfg)
        return session
    }

    /// Shift every clip's start by `-frames` so text aligns when the range is rebased to 0.
    private static func rebased(_ timeline: Timeline, by frames: Int) -> Timeline {
        var t = timeline
        t.tracks = timeline.tracks.map { track in
            var tr = track
            tr.clips = track.clips.map { var c = $0; c.startFrame -= frames; return c }
            return tr
        }
        return t
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
