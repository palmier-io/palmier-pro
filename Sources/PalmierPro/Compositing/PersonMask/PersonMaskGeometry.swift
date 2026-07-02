import CoreImage
import Foundation

/// CI-based geometry helpers for comparing Vision masks/boxes. Every mask is rendered into a
/// small fixed-size grid (same trick as `ColorScopes`) so comparisons are resolution-independent
/// and don't need to touch raw pixel formats.
enum PersonMaskGeometry {
    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private static let gridEdge = 48
    private static let onThreshold: UInt8 = 32

    /// Normalized (0...1, bottom-left origin) bounding box of a mask's non-background pixels.
    static func boundingBox(of mask: CIImage) -> CGRect? {
        guard let grid = render(mask) else { return nil }
        var minX = gridEdge, maxX = -1, minY = gridEdge, maxY = -1
        for y in 0..<gridEdge {
            for x in 0..<gridEdge where grid[y * gridEdge + x] > onThreshold {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let n = CGFloat(gridEdge)
        return CGRect(
            x: CGFloat(minX) / n, y: CGFloat(minY) / n,
            width: CGFloat(maxX - minX + 1) / n, height: CGFloat(maxY - minY + 1) / n
        )
    }

    /// Intersection-over-union between a mask's on-pixels and a normalized (0...1) box.
    static func overlap(of mask: CIImage, with box: CGRect) -> Double {
        guard let grid = render(mask) else { return 0 }
        let n = gridEdge
        let minX = Int((box.minX * CGFloat(n)).rounded(.down))
        let maxX = Int((box.maxX * CGFloat(n)).rounded(.up))
        let minY = Int((box.minY * CGFloat(n)).rounded(.down))
        let maxY = Int((box.maxY * CGFloat(n)).rounded(.up))
        var maskOn = 0, boxCells = 0, intersection = 0
        for y in 0..<n {
            let rowInBox = y >= minY && y < maxY
            for x in 0..<n {
                let on = grid[y * n + x] > onThreshold
                let inBox = rowInBox && x >= minX && x < maxX
                if on { maskOn += 1 }
                if inBox { boxCells += 1 }
                if on && inBox { intersection += 1 }
            }
        }
        let union = maskOn + boxCells - intersection
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    /// Intersection-over-union between two masks' on-pixel regions.
    static func overlap(_ maskA: CIImage, _ maskB: CIImage) -> Double {
        guard let gridA = render(maskA), let gridB = render(maskB) else { return 0 }
        var onA = 0, onB = 0, intersection = 0
        for i in 0..<(gridEdge * gridEdge) {
            let a = gridA[i] > onThreshold, b = gridB[i] > onThreshold
            if a { onA += 1 }
            if b { onB += 1 }
            if a && b { intersection += 1 }
        }
        let union = onA + onB - intersection
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    /// Renders a mask's red channel into a fixed-size grid, one byte per cell.
    private static func render(_ mask: CIImage) -> [UInt8]? {
        let extent = mask.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return nil }
        let n = CGFloat(gridEdge)
        let scaled = mask
            .transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
            .transformed(by: CGAffineTransform(scaleX: n / extent.width, y: n / extent.height))
        var bytes = [UInt8](repeating: 0, count: gridEdge * gridEdge * 4)
        bytes.withUnsafeMutableBytes {
            context.render(scaled, toBitmap: $0.baseAddress!, rowBytes: gridEdge * 4,
                           bounds: CGRect(x: 0, y: 0, width: n, height: n),
                           format: .RGBA8, colorSpace: nil)
        }
        var grid = [UInt8](repeating: 0, count: gridEdge * gridEdge)
        for i in 0..<(gridEdge * gridEdge) { grid[i] = bytes[i * 4] }
        return grid
    }
}
