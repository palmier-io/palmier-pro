import AVFoundation
import Foundation

extension ToolExecutor {
    private static let inspectTimelineAllowedKeys: Set<String> = ["startFrame", "endFrame", "maxFrames"]
    private static let inspectTimelineDefaultFrames = 6
    private static let inspectTimelineMaxFrames = 12
    private static let inspectTimelineMaxDimension: CGFloat = 512
    private static let inspectTimelineJPEGQuality: CGFloat = 0.7

    /// Renders the composited timeline at one or more frames
    func inspectTimeline(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.inspectTimelineAllowedKeys, path: "inspect_timeline")

        let timeline = editor.timeline
        let totalFrames = timeline.totalFrames
        guard totalFrames > 0 else { throw ToolError("Timeline is empty — nothing to render.") }

        let startFrame = args.int("startFrame") ?? 0
        guard startFrame >= 0, startFrame < totalFrames else {
            throw ToolError("startFrame \(startFrame) out of range [0, \(totalFrames)).")
        }

        let sampledFrames: [Int]
        if let rawEnd = args.int("endFrame") {
            let endFrame = min(rawEnd, totalFrames)
            guard endFrame > startFrame else {
                throw ToolError("endFrame must be greater than startFrame (\(startFrame)).")
            }
            let span = endFrame - startFrame
            let count = max(1, min(args.int("maxFrames") ?? Self.inspectTimelineDefaultFrames, Self.inspectTimelineMaxFrames, span))
            sampledFrames = (0..<count).map {
                startFrame + Int((Double(span) * (Double($0) + 0.5) / Double(count)).rounded(.down))
            }
        } else {
            sampledFrames = [startFrame]
        }

        let canvas = CGSize(width: timeline.width, height: timeline.height)
        let renderSize = Self.fit(canvas, longestEdge: Self.inspectTimelineMaxDimension)
        let mediaURLs = editor.mediaResolver.expectedURLMap()
        let composition = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { mediaURLs[$0] },
            missingMediaRefs: editor.missingMediaRefs,
            renderSize: canvas
        )

        guard (try? await composition.composition.loadTracks(withMediaType: .video).first) != nil else {
            throw ToolError("No video track available in timeline.")
        }
        let generator = AVAssetImageGenerator(asset: composition.composition)
        generator.videoComposition = composition.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = renderSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let timescale = CMTimeScale(timeline.fps)
        var imageBlocks: [ToolResult.Block] = []
        var renderedFrames: [Int] = []
        for frame in sampledFrames {
            let time = CMTime(value: CMTimeValue(frame), timescale: timescale)
            guard let videoCG = try? await generator.image(at: time).image else { continue }
            let frameCanvas = CGSize(width: videoCG.width, height: videoCG.height)
            let textRoot = TextLayerController.buildSnapshot(timeline: timeline, canvasSize: frameCanvas, atFrame: frame)
            guard let composited = EditorViewModel.compositeCapture(video: videoCG, textRoot: textRoot, canvas: frameCanvas),
                  let jpeg = ImageEncoder.encodeJPEG(composited, quality: Self.inspectTimelineJPEGQuality) else { continue }
            imageBlocks.append(.image(base64: jpeg.base64EncodedString(), mediaType: "image/jpeg"))
            renderedFrames.append(frame)
        }
        guard !imageBlocks.isEmpty else { throw ToolError("Failed to render timeline frames.") }

        let meta: [String: Any] = [
            "fps": timeline.fps,
            "width": Int(renderSize.width),
            "height": Int(renderSize.height),
            "totalFrames": totalFrames,
            "frameNumbers": renderedFrames,
        ]
        guard let metaJSON = Self.jsonString(meta) else { throw ToolError("Failed to encode metadata") }
        return ToolResult(content: imageBlocks + [.text(metaJSON)], isError: false)
    }

    /// Aspect-preserving size whose longest edge is at most `longestEdge`.
    private static func fit(_ size: CGSize, longestEdge: CGFloat) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > longestEdge else { return size }
        let scale = longestEdge / longest
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
