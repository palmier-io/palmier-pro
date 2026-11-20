import AVFoundation
import AppKit
import CoreGraphics
import Foundation

/// A platform's thumbnail shape and file budget.
///
/// YouTube and the social platforms each reject an image that misses their spec, so the target
/// is a named preset rather than a free width/height pair the Agent has to remember.
enum ThumbnailPreset: String, Sendable, CaseIterable {
    /// 1280x720, under 2 MB. The default for a horizontal video.
    case youtube
    /// 1080x1920. Shorts, Reels and TikTok.
    case vertical
    /// 1080x1080. Feed posts.
    case square
    /// The project's own canvas, cropped to 16:9. For when the video is not a platform upload.
    case timeline

    var size: CGSize {
        switch self {
        case .youtube: CGSize(width: 1280, height: 720)
        case .vertical: CGSize(width: 1080, height: 1920)
        case .square: CGSize(width: 1080, height: 1080)
        case .timeline: CGSize(width: 1280, height: 720)
        }
    }

    /// Hard ceiling in bytes. 2 MB is YouTube's published limit and the strictest of the group.
    var maxBytes: Int {
        switch self {
        case .youtube, .timeline: 2 * 1024 * 1024
        case .vertical, .square: 4 * 1024 * 1024
        }
    }

    var guidance: String {
        switch self {
        case .youtube: "1280x720, 16:9, under 2 MB."
        case .vertical: "1080x1920, 9:16, under 4 MB."
        case .square: "1080x1080, 1:1, under 4 MB."
        case .timeline: "1280x720, cropped from the project's own canvas."
        }
    }
}

/// Where the headline sits, as a fraction of the frame. Kept coarse because a thumbnail read at
/// a glance needs one obvious place for the words.
enum ThumbnailTextPlacement: String, Sendable, CaseIterable {
    case bottomLeft
    case bottomCenter
    case centerLeft
    case center

    /// Text box origin and size as fractions of the output frame.
    var box: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        switch self {
        case .bottomLeft: (0.06, 0.62, 0.76, 0.26)
        case .bottomCenter: (0.10, 0.62, 0.80, 0.26)
        case .centerLeft: (0.06, 0.30, 0.76, 0.30)
        case .center: (0.10, 0.30, 0.80, 0.30)
        }
    }
}

struct ThumbnailSpec: Sendable, Equatable {
    var preset: ThumbnailPreset = .youtube
    /// Headline. Empty means no text, which is a legitimate thumbnail.
    var title: String = ""
    /// Secondary line under the headline.
    var subtitle: String = ""
    var placement: ThumbnailTextPlacement = .bottomLeft
    /// Relative to the frame's long edge, so it reads the same on every preset.
    var titleScale: Double = 0.11
    /// Darkens the text band so light words stay legible over a bright frame.
    var scrim: Bool = true
}

/// Renders a poster frame for a timeline. Deliberately separate from the video: it never touches
/// the timeline, never becomes a media asset, and is written as its own file the user can upload.
enum ThumbnailRenderer {
    enum RenderError: Error, CustomStringConvertible {
        case noVideoTrack
        case renderFailed(String)
        case encodeFailed
        case overBudget(bytes: Int, limit: Int)

        var description: String {
            switch self {
            case .noVideoTrack: "The timeline has no picture to make a thumbnail from."
            case .renderFailed(let reason): "Could not render the thumbnail frame: \(reason)"
            case .encodeFailed: "Could not encode the thumbnail."
            case .overBudget(let bytes, let limit):
                "The thumbnail is \(bytes / 1024) KB, over the \(limit / 1024) KB limit even at the lowest quality."
            }
        }
    }

    /// Fills the target with the frame, cropping the overflow. Cover, never fit: letterboxing a
    /// thumbnail wastes the pixels that make it readable at a glance.
    nonisolated static func coverCrop(_ image: CGImage, to size: CGSize) -> CGImage {
        let source = CGRect(origin: .zero, size: CGSize(width: image.width, height: image.height))
        let targetRatio = size.width / size.height
        let sourceRatio = source.width / source.height
        var crop = source
        if sourceRatio > targetRatio {
            // Source is wider: take the full height and centre horizontally.
            let width = source.height * targetRatio
            crop = CGRect(x: (source.width - width) / 2, y: 0, width: width, height: source.height)
        } else if sourceRatio < targetRatio {
            let height = source.width / targetRatio
            crop = CGRect(x: 0, y: (source.height - height) / 2, width: source.width, height: height)
        }
        guard let cropped = image.cropping(to: crop) else { return image }
        return ThumbnailRenderer.scale(cropped, to: size)
    }

    nonisolated static func scale(_ image: CGImage, to size: CGSize) -> CGImage {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0, (image.width != width || image.height != height) else { return image }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Draws the headline and optional subline. Returns the image unchanged for empty text, so a
    /// clean poster stays clean.
    nonisolated static func applyText(
        to image: CGImage, spec: ThumbnailSpec
    ) -> CGImage? {
        let headline = spec.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sub = spec.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !headline.isEmpty || !sub.isEmpty else { return image }
        let size = CGSize(width: image.width, height: image.height)
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(origin: .zero, size: size))

        let box = spec.placement.box
        let textRect = CGRect(
            x: size.width * box.x,
            y: size.height * (1 - box.y - box.height),
            width: size.width * box.width,
            height: size.height * box.height
        )
        if spec.scrim {
            context.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
            context.fill(textRect.insetBy(dx: -textRect.width * 0.03, dy: -textRect.height * 0.06))
        }

        let longEdge = max(size.width, size.height)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: longEdge * CGFloat(spec.titleScale), weight: .heavy),
            .foregroundColor: NSColor.white,
        ]
        // A dark edge behind light words, so a busy frame cannot swallow the headline.
        attributes[.strokeColor] = NSColor.black.withAlphaComponent(0.85)
        attributes[.strokeWidth] = -max(2, longEdge * CGFloat(spec.titleScale) * 0.045)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = spec.placement == .bottomCenter || spec.placement == .center
            ? .center
            : .left
        paragraph.lineBreakMode = .byWordWrapping
        attributes[.paragraphStyle] = paragraph

        let headlineFont = attributes[.font] as? NSFont
        let headlineRect = headline.isEmpty ? .zero : textRect
        if !headline.isEmpty {
            NSString(string: headline).draw(
                with: headlineRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: attributes, context: nil
            )
        }
        if !sub.isEmpty {
            var subAttributes = attributes
            let size = (headlineFont?.pointSize ?? longEdge * CGFloat(spec.titleScale)) * 0.46
            subAttributes[.font] = NSFont.systemFont(ofSize: size, weight: .semibold)
            subAttributes[.strokeWidth] = -max(1, size * 0.05)
            let subRect = CGRect(
                x: textRect.minX, y: textRect.minY - textRect.height * 0.30,
                width: textRect.width, height: textRect.height * 0.30
            )
            NSString(string: sub).draw(
                with: subRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: subAttributes, context: nil
            )
        }
        return context.makeImage()
    }

    /// JPEG at the highest quality that fits the budget, so the file stays under the platform
    /// limit instead of being rejected at upload.
    nonisolated static func encode(_ image: CGImage, preset: ThumbnailPreset) throws -> Data {
        var data = ImageEncoder.encodeJPEG(image, quality: 0.92)
        var quality: CGFloat = 0.92
        while let current = data, current.count > preset.maxBytes, quality > 0.4 {
            quality -= 0.08
            data = ImageEncoder.encodeJPEG(image, quality: quality)
        }
        guard let final = data, !final.isEmpty else { throw RenderError.encodeFailed }
        if final.count > preset.maxBytes { throw RenderError.overBudget(bytes: final.count, limit: preset.maxBytes) }
        return final
    }

    /// Scores a frame for poster-worthiness: detail and contrast read as a real image, while a
    /// flat or blown-out frame reads as a mistake. Deliberately simple and explainable, and never
    /// presented as "the best frame" — it is the most legible frame.
    nonisolated static func score(_ image: CGImage) -> Double {
        let width = min(image.width, 160)
        let height = min(image.height, 160)
        guard width > 1, height > 1,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return 0 }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // makeImage() forces the draw to land before the buffer is read back.
        _ = context.makeImage()
        guard let data = context.data else { return 0 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var lumas: [Double] = []
        lumas.reserveCapacity(width * height)
        for index in stride(from: 0, to: width * height, by: 1) {
            let base = index * 4
            let r = Double(bytes[base]), g = Double(bytes[base + 1]), b = Double(bytes[base + 2])
            lumas.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        let mean = lumas.reduce(0, +) / Double(lumas.count)
        let variance = lumas.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lumas.count)
        let contrast = variance.squareRoot() / 255.0
        // Penalise frames that are crushed or blown out; a poster has to hold detail at a glance.
        let clippedCount = lumas.filter { $0 < 6 || $0 > 249 }.count
        let clipped = Double(clippedCount) / Double(lumas.count)
        return contrast - clipped * 1.5
    }
}