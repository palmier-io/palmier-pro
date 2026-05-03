import AppKit

enum TimelineRuler {

    static func draw(
        in rect: NSRect,
        fps: Int,
        pixelsPerFrame: Double,
        scrollOffsetX: CGFloat,
        context: CGContext
    ) {
        // Background
        context.setFillColor(AppTheme.Background.surface.cgColor)
        context.fill(rect)

        // Bottom separator
        context.setStrokeColor(AppTheme.Border.primary.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: rect.minX, y: rect.maxY - 0.5))
        context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 0.5))
        context.strokePath()

        // Tick math divides by pixelsPerFrame and casts to Int — NaN/±Inf would trap.
        guard pixelsPerFrame > 0, pixelsPerFrame.isFinite else { return }

        // Adaptive tick interval: target ~80px between major ticks
        let framesPerMajor = tickInterval(pixelsPerFrame: pixelsPerFrame, fps: fps)
        guard framesPerMajor > 0 else { return }

        let startFrame = max(0, Int(scrollOffsetX / pixelsPerFrame) - framesPerMajor)
        let endFrame = Int((scrollOffsetX + rect.width) / pixelsPerFrame) + framesPerMajor

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: AppTheme.Text.tertiary,
        ]

        // Minor ticks: subdivide each major interval
        let minorCount = minorSubdivisions(framesPerMajor: framesPerMajor, pixelsPerFrame: pixelsPerFrame, fps: fps)
        let framesPerMinor = minorCount > 0 ? framesPerMajor / minorCount : 0

        // Draw minor ticks first (so major ticks draw on top)
        if framesPerMinor > 0 {
            context.setStrokeColor(AppTheme.Text.muted.withAlphaComponent(0.4).cgColor)
            context.setLineWidth(0.5)
            var minorFrame = (startFrame / framesPerMinor) * framesPerMinor
            while minorFrame <= endFrame {
                if minorFrame % framesPerMajor != 0 {
                    let localX = Double(minorFrame) * pixelsPerFrame - scrollOffsetX
                    if localX >= 0 && localX <= Double(rect.width) {
                        let x = Double(rect.minX) + localX
                        let isMidpoint = minorCount % 2 == 0 && minorFrame % (framesPerMajor / 2) == 0
                        let tickHeight: Double = isMidpoint ? 6 : 4
                        context.move(to: CGPoint(x: x, y: Double(rect.maxY) - tickHeight))
                        context.addLine(to: CGPoint(x: x, y: Double(rect.maxY)))
                        context.strokePath()
                    }
                }
                minorFrame += framesPerMinor
            }
        }

        // Draw major ticks and labels
        var frame = (startFrame / framesPerMajor) * framesPerMajor
        while frame <= endFrame {
            let localX = Double(frame) * pixelsPerFrame - scrollOffsetX
            guard localX >= 0 && localX <= Double(rect.width) else { frame += framesPerMajor; continue }
            let x = Double(rect.minX) + localX

            // Major tick
            context.setStrokeColor(AppTheme.Text.muted.cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: x, y: Double(rect.maxY) - 8))
            context.addLine(to: CGPoint(x: x, y: Double(rect.maxY)))
            context.strokePath()

            // Time label
            let label = formatTimecode(frame: frame, fps: fps)
            let str = NSAttributedString(string: label, attributes: attrs)
            str.draw(at: NSPoint(x: x + 3, y: rect.minY + 2))

            frame += framesPerMajor
        }
    }

    /// Choose a tick interval that keeps major ticks ~80px apart.
    private static func tickInterval(pixelsPerFrame: Double, fps: Int) -> Int {
        let targetPixels = 80.0
        let rawFrames = targetPixels / pixelsPerFrame

        // Round to "nice" intervals: 1s, 2s, 5s, 10s, 30s, 1m, 5m, 10m
        let candidates = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600].map { $0 * fps }
        return candidates.first { Double($0) >= rawFrames } ?? candidates.last!
    }

    /// How many minor subdivisions fit between major ticks
    private static func minorSubdivisions(framesPerMajor: Int, pixelsPerFrame: Double, fps: Int) -> Int {
        let majorPixels = Double(framesPerMajor) * pixelsPerFrame
        // Try 10, 5, 4, 2 subdivisions — pick the first where each minor tick is >= 12px apart
        for divisions in [10, 5, 4, 2] {
            if majorPixels / Double(divisions) >= 12 {
                return divisions
            }
        }
        return 0
    }
}
