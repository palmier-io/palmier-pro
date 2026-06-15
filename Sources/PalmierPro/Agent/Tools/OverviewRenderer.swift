import AVFoundation
import CoreGraphics
import CoreText
import Foundation

/// Composites a video's visual flow into one storyboard image: dense keyframe-snapped
/// sampling, near-duplicate tiles dropped, timestamps burned into each kept tile.
enum OverviewRenderer {
    struct Sheet {
        let jpeg: Data
        let timestamps: [Double]
    }

    struct RenderError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let tileWidth = 160
    private static let tileHeight = 90
    private static let columns = 6
    private static let maxTiles = 36
    private static let candidateTarget = 120.0
    private static let promoteDiff: Float = 12
    private static let labelHeight = 14
    private static let jpegQuality: CGFloat = 0.7

    static func make(url: URL, start: Double, end: Double) async throws -> Sheet {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: tileWidth * 2, height: tileHeight * 2)
        let span = max(end - start, 0.001)
        let interval = max(1.0, span / candidateTarget)
        let tolerance = CMTime(seconds: interval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let times = stride(from: start + interval / 2, to: end, by: interval)
            .map { CMTime(seconds: $0, preferredTimescale: 600) }
        guard !times.isEmpty else { throw RenderError(message: "Window too short for a overview") }

        var tiles: [(t: Double, image: CGImage)] = []
        var lastGrid: [Float]?
        for await result in generator.images(for: times) {
            guard case .success(_, let image, let actualTime) = result else { continue }
            let t = actualTime.seconds
            if let last = tiles.last, t <= last.t { continue }
            guard let grid = LumaGrid.compute(image) else { continue }
            if let last = lastGrid {
                guard LumaGrid.meanDiff(grid, last) > promoteDiff else { continue }
            }
            lastGrid = grid
            tiles.append((t, image))
        }
        guard !tiles.isEmpty else { throw RenderError(message: "Could not decode frames for overview") }

        if tiles.count > maxTiles {
            let step = Double(tiles.count) / Double(maxTiles)
            tiles = (0..<maxTiles).map { tiles[Int(Double($0) * step)] }
        }
        guard let composed = render(tiles), let jpeg = ImageEncoder.encodeJPEG(composed, quality: jpegQuality) else {
            throw RenderError(message: "Failed to compose overview")
        }
        return Sheet(jpeg: jpeg, timestamps: tiles.map(\.t))
    }

    private static func render(_ tiles: [(t: Double, image: CGImage)]) -> CGImage? {
        let cols = min(columns, tiles.count)
        let rows = (tiles.count + cols - 1) / cols
        guard let ctx = CGContext(
            data: nil, width: cols * tileWidth, height: rows * tileHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cols * tileWidth, height: rows * tileHeight))
        ctx.interpolationQuality = .high

        for (i, tile) in tiles.enumerated() {
            let x = (i % cols) * tileWidth
            let y = (rows - 1 - i / cols) * tileHeight
            ctx.draw(tile.image, in: CGRect(x: x, y: y, width: tileWidth, height: tileHeight))
            drawLabel(timeLabel(tile.t), in: ctx, cellX: x, cellTopY: y + tileHeight)
        }
        return ctx.makeImage()
    }

    private static func drawLabel(_ text: String, in ctx: CGContext, cellX: Int, cellTopY: Int) {
        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica-Bold" as CFString, 10, nil),
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.65))
        ctx.fill(CGRect(x: cellX, y: cellTopY - labelHeight, width: Int(width) + 8, height: labelHeight))
        ctx.textPosition = CGPoint(x: CGFloat(cellX) + 4, y: CGFloat(cellTopY - labelHeight) + 3.5)
        CTLineDraw(line, ctx)
    }

    private static func timeLabel(_ t: Double) -> String {
        let s = Int(t.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
