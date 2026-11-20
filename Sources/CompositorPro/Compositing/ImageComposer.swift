import CoreGraphics
import Foundation

/// How several source images are arranged into one output image.
enum ComposeLayout: String, Sendable, CaseIterable {
    /// Even tiles, with the column count chosen so tile shape suits the canvas.
    case grid
    /// One image large on top, the remainder as a strip beneath it. Reads as a poster.
    case heroStrip
    /// A single row across the canvas. Best for a handful of frames.
    case row
    /// A single column down the canvas.
    case column

    var guidance: String {
        switch self {
        case .grid: "Even tiles. Contact sheets and mood boards."
        case .heroStrip: "One image large, the rest as a strip beneath. Posters."
        case .row: "A single row across. Short sequences."
        case .column: "A single column down."
        }
    }
}

/// Composes several images into one, locally.
///
/// This is assembly, not synthesis: it lays out the project's own frames and stills. It reuses
/// `ThumbnailRenderer`'s cover-crop, scale and text drawing rather than introducing a second
/// renderer, so a composed image and a thumbnail are lettered identically.
enum ImageComposer {
    /// Gap between tiles and around the edge, as a fraction of the canvas's short side.
    static let gutter: CGFloat = 0.012
    /// Fraction of the canvas height given to the hero image in `heroStrip`.
    static let heroShare: CGFloat = 0.68

    struct Spec: Sendable, Equatable {
        var layout: ComposeLayout = .grid
        var canvas: CGSize = CGSize(width: 1280, height: 720)
        var headline: String = ""
        var subline: String = ""
        var placement: ThumbnailTextPlacement = .bottomLeft
        var scrim: Bool = true

        var isValid: Bool { canvas.width >= 16 && canvas.height >= 16 }
    }

    enum ComposeError: Error, Equatable, CustomStringConvertible {
        case noImages
        case canvasTooSmall

        var description: String {
            switch self {
            case .noImages: "No images to compose."
            case .canvasTooSmall: "The output canvas must be at least 16x16 pixels."
            }
        }
    }

    /// Lays out `images` and draws them, cropped to fill each slot rather than letterboxed.
    static func compose(_ images: [CGImage], spec: Spec) throws -> CGImage {
        guard !images.isEmpty else { throw ComposeError.noImages }
        guard spec.isValid else { throw ComposeError.canvasTooSmall }
        let canvas = CGSize(
            width: Int(spec.canvas.width.rounded()),
            height: Int(spec.canvas.height.rounded())
        )
        guard let context = makeContext(size: canvas) else { throw ComposeError.canvasTooSmall }
        // Flipped so image coordinates run top-left to bottom-right like the layout maths.
        context.translateBy(x: 0, y: CGFloat(canvas.height))
        context.scaleBy(x: 1, y: -1)

        let slots = slots(count: images.count, layout: spec.layout, canvas: spec.canvas)
        for (index, image) in images.enumerated() {
            guard let slot = slots[safe: index] else { continue }
            let slotSize = CGSize(width: max(1, slot.width), height: max(1, slot.height))
            let filled = ThumbnailRenderer.coverCrop(image, to: slotSize)
            context.draw(filled, in: CGRect(origin: slot.origin, size: slotSize))
        }
        guard let composed = context.makeImage() else { throw ComposeError.canvasTooSmall }

        let textSpec = ThumbnailSpec(
            title: spec.headline, subtitle: spec.subline, placement: spec.placement, scrim: spec.scrim
        )
        return ThumbnailRenderer.applyText(to: composed, spec: textSpec) ?? composed
    }

    /// Destination rectangles for each tile, in unflipped top-left coordinates.
    static func slots(count: Int, layout: ComposeLayout, canvas: CGSize) -> [CGRect] {
        guard count > 0 else { return [] }
        // One image is the whole picture. A gutter would frame it with dead space, so the layout
        // does not apply at all.
        guard count > 1 else { return [CGRect(origin: .zero, size: canvas)] }
        let gap = gutter(for: canvas)
        switch layout {
        case .row:
            return rowSlots(count: count, canvas: canvas, gap: gap)
        case .column:
            return columnSlots(count: count, canvas: canvas, gap: gap)
        case .heroStrip:
            return heroStripSlots(count: count, canvas: canvas, gap: gap)
        case .grid:
            return gridSlots(count: count, canvas: canvas, gap: gap)
        }
    }

    static func gutter(for canvas: CGSize) -> CGFloat {
        gutter * min(canvas.width, canvas.height)
    }

    private static func gridSlots(count: Int, canvas: CGSize, gap: CGFloat) -> [CGRect] {
        let columns = gridColumns(count: count, canvas: canvas)
        let rows = Int(ceil(Double(count) / Double(columns)))
        let cellWidth = (canvas.width - gap * CGFloat(columns + 1)) / CGFloat(columns)
        let cellHeight = (canvas.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
        return (0 ..< count).map { index in
            let column = index % columns
            let row = index / columns
            return CGRect(
                x: gap + CGFloat(column) * (cellWidth + gap),
                y: gap + CGFloat(row) * (cellHeight + gap),
                width: cellWidth,
                height: cellHeight
            )
        }
    }

    /// The column count whose tile shape most nearly matches the canvas, so a grid of landscape
    /// frames does not end up as tall skinny tiles on a landscape canvas.
    static func gridColumns(count: Int, canvas: CGSize) -> Int {
        guard count > 1, canvas.width > 0, canvas.height > 0 else { return 1 }
        let target = Double(canvas.width / canvas.height)
        var best = 1
        var bestError = Double.greatestFiniteMagnitude
        for columns in 1 ... count {
            let rows = Int(ceil(Double(count) / Double(columns)))
            let ratio = Double(columns) / Double(rows)
            guard ratio > 0 else { continue }
            let error = abs(log(ratio / target))
            if error < bestError {
                bestError = error
                best = columns
            }
        }
        return best
    }

    private static func rowSlots(count: Int, canvas: CGSize, gap: CGFloat) -> [CGRect] {
        let cellWidth = (canvas.width - gap * CGFloat(count + 1)) / CGFloat(count)
        return (0 ..< count).map { index in
            CGRect(
                x: gap + CGFloat(index) * (cellWidth + gap),
                y: gap,
                width: cellWidth,
                height: canvas.height - gap * 2
            )
        }
    }

    private static func columnSlots(count: Int, canvas: CGSize, gap: CGFloat) -> [CGRect] {
        let cellHeight = (canvas.height - gap * CGFloat(count + 1)) / CGFloat(count)
        return (0 ..< count).map { index in
            CGRect(
                x: gap,
                y: gap + CGFloat(index) * (cellHeight + gap),
                width: canvas.width - gap * 2,
                height: cellHeight
            )
        }
    }

    private static func heroStripSlots(count: Int, canvas: CGSize, gap: CGFloat) -> [CGRect] {
        let heroHeight = canvas.height * heroShare
        let stripTop = heroHeight + gap
        let stripHeight = canvas.height - stripTop - gap
        let stripCount = count - 1
        let cellWidth = (canvas.width - gap * CGFloat(stripCount + 1)) / CGFloat(stripCount)
        var rects = [CGRect(x: 0, y: 0, width: canvas.width, height: heroHeight)]
        for index in 0 ..< stripCount {
            rects.append(CGRect(
                x: gap + CGFloat(index) * (cellWidth + gap),
                y: stripTop,
                width: cellWidth,
                height: stripHeight
            ))
        }
        return rects
    }

    private static func makeContext(size: CGSize) -> CGContext? {
        CGContext(
            data: nil,
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}