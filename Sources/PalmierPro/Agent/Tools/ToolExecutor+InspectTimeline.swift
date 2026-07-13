import AVFoundation
import CoreText
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
            resolveTimeline: editor.timelineResolver(),
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
            // videoComposition already composites text via CustomVideoCompositor.
            let labeled = Self.burnLabel("f\(frame)", into: videoCG) ?? videoCG
            guard let jpeg = ImageEncoder.encodeJPEG(labeled, quality: Self.inspectTimelineJPEGQuality) else { continue }
            imageBlocks.append(.image(base64: jpeg.base64EncodedString(), mediaType: "image/jpeg"))
            renderedFrames.append(frame)
        }
        guard !imageBlocks.isEmpty else { throw ToolError("Failed to render timeline frames.") }

        let meta: [String: Any] = [
            "fps": timeline.fps,
            "width": Int(renderSize.width),
            "height": Int(renderSize.height),
            "totalFrames": totalFrames,
            "frames": renderedFrames.map { frame -> [String: Any] in
                ["frame": frame, "clips": Self.visibleClips(at: frame, in: timeline)]
            },
        ]
        guard let metaJSON = Self.jsonString(meta) else { throw ToolError("Failed to encode metadata") }
        return ToolResult(content: imageBlocks + [.text(metaJSON)], isError: false)
    }

    /// Ids of visual clips on screen at `frame`, top track first; caption clips report their group id once.
    static func visibleClips(at frame: Int, in timeline: Timeline) -> [String] {
        var ids: [String] = []
        var seenGroups = Set<String>()
        for track in timeline.tracks where track.type == .video && !track.hidden {
            for clip in track.clips where clip.startFrame <= frame && frame < clip.startFrame + clip.durationFrames {
                if let gid = clip.captionGroupId {
                    if seenGroups.insert(gid).inserted { ids.append(gid) }
                } else {
                    ids.append(clip.id)
                }
            }
        }
        return ids
    }

    /// Draws a small frame-number chip in the top-left so each image self-identifies.
    private static func burnLabel(_ text: String, into image: CGImage) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica-Bold" as CFString, 12, nil),
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let chipHeight: CGFloat = 16
        let chipTop = CGFloat(image.height)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.65))
        ctx.fill(CGRect(x: 0, y: chipTop - chipHeight, width: textWidth + 10, height: chipHeight))
        ctx.textPosition = CGPoint(x: 5, y: chipTop - chipHeight + 4)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    /// Aspect-preserving size whose longest edge is at most `longestEdge`.
    private static func fit(_ size: CGSize, longestEdge: CGFloat) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > longestEdge else { return size }
        let scale = longestEdge / longest
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
