import AVFoundation
import CoreText
import Foundation

enum TimelineFrameSampler {
    static let defaultFrameCount = 6
    static let maxFrameCount = 12
    static let maxDimension: CGFloat = 512
    static let jpegQuality: CGFloat = 0.7

    struct Frame: Sendable {
        let frame: Int
        let jpeg: Data
        let clipIds: [String]
        let width: Int
        let height: Int
    }

    @MainActor
    static func sample(
        timeline: Timeline,
        editor: EditorViewModel,
        startFrame: Int,
        endFrame: Int?,
        maxFrames: Int,
        burnLabels: Bool
    ) async throws -> [Frame] {
        let totalFrames = timeline.totalFrames
        guard totalFrames > 0 else { throw ToolError("Timeline is empty — nothing to render.") }
        guard startFrame >= 0, startFrame < totalFrames else {
            throw ToolError("startFrame \(startFrame) out of range [0, \(totalFrames)).")
        }

        let sampledFrames: [Int]
        if let rawEnd = endFrame, rawEnd != 0 {
            let endFrame = min(rawEnd, totalFrames)
            guard endFrame > startFrame else {
                throw ToolError("endFrame must be greater than startFrame (\(startFrame)).")
            }
            let span = endFrame - startFrame
            let count = max(1, min(maxFrames, Self.maxFrameCount, span))
            sampledFrames = (0..<count).map {
                startFrame + Int((Double(span) * (Double($0) + 0.5) / Double(count)).rounded(.down))
            }
        } else {
            sampledFrames = [startFrame]
        }

        let canvas = CGSize(width: timeline.width, height: timeline.height)
        let renderSize = fit(canvas, longestEdge: maxDimension)
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
        var frames: [Frame] = []
        frames.reserveCapacity(sampledFrames.count)
        for frame in sampledFrames {
            let time = CMTime(value: CMTimeValue(frame), timescale: timescale)
            guard let videoCG = try? await generator.image(at: time).image else { continue }
            let labeled = burnLabels ? (burnLabel("f\(frame)", into: videoCG) ?? videoCG) : videoCG
            guard let jpeg = ImageEncoder.encodeJPEG(labeled, quality: jpegQuality) else { continue }
            frames.append(
                Frame(
                    frame: frame,
                    jpeg: jpeg,
                    clipIds: visibleClips(at: frame, in: timeline),
                    width: Int(renderSize.width),
                    height: Int(renderSize.height)
                )
            )
        }
        guard !frames.isEmpty else { throw ToolError("Failed to render timeline frames.") }
        return frames
    }

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

    static func fit(_ size: CGSize, longestEdge: CGFloat) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > longestEdge else { return size }
        let scale = longestEdge / longest
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

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
}
