import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum GapTransitionFrameRenderer {
    struct RenderError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func renderBoundaryFrames(
        timeline: Timeline,
        context: GapTransitionContext,
        mediaURLs: [String: URL],
        sourceSizes: [String: CGSize],
        resolveTimeline: @escaping @Sendable (String) -> Timeline?,
        missingMediaRefs: Set<String>
    ) async throws -> [Data] {
        guard let track = timeline.tracks.first(where: { $0.id == context.trackId }),
              let previous = track.clips.first(where: { $0.id == context.previousClipId }),
              let next = track.clips.first(where: { $0.id == context.nextClipId }) else {
            throw RenderError(message: "The clips around this gap changed.")
        }

        var isolatedTrack = track
        isolatedTrack.hidden = false
        isolatedTrack.clips = [previous, next]
        var isolatedTimeline = timeline
        isolatedTimeline.tracks = [isolatedTrack]

        let canvas = CGSize(width: timeline.width, height: timeline.height)
        let composition = try await CompositionBuilder.build(
            timeline: isolatedTimeline,
            resolveURL: { mediaURLs[$0] },
            resolveSourceSize: { sourceSizes[$0] },
            resolveTimeline: resolveTimeline,
            missingMediaRefs: missingMediaRefs,
            renderSize: canvas
        )
        guard composition.offlineMediaRefs.isEmpty,
              composition.unprocessableMediaRefs.isEmpty,
              (try? await composition.composition.loadTracks(withMediaType: .video).first) != nil else {
            throw RenderError(message: "The transition frames could not be rendered.")
        }

        let generator = AVAssetImageGenerator(asset: composition.composition)
        generator.videoComposition = composition.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = canvas
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let timescale = CMTimeScale(timeline.fps)
        let frames = [context.range.start - 1, context.range.end]
        var output: [Data] = []
        output.reserveCapacity(frames.count)
        for frame in frames {
            try Task.checkCancellation()
            let time = CMTime(value: CMTimeValue(frame), timescale: timescale)
            let image = try await generator.image(at: time).image
            guard let data = pngData(for: image) else {
                throw RenderError(message: "The transition frame could not be encoded.")
            }
            output.append(data)
        }
        return output
    }

    private static func pngData(for image: CGImage) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? buffer as Data : nil
    }
}
