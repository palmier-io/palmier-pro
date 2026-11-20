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

        // Tick math divides by pixelsPerFrame and casts to Int — NaN/±Inf would trap.
        guard pixelsPerFrame > 0, pixelsPerFrame.isFinite else { return }

        let framesPerMajor = tickInterval(pixelsPerFrame: pixelsPerFrame, fps: fps)
        guard framesPerMajor > 0 else { return }

        let startFrame = max(0, Int(scrollOffsetX / pixelsPerFrame) - framesPerMajor)
        let endFrame = Int((scrollOffsetX + rect.width) / pixelsPerFrame) + framesPerMajor

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: AppTheme.FontSize.xs, weight: .regular),
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
                        let tickHeight: Double = isMidpoint ? AppTheme.Spacing.sm : AppTheme.Spacing.xs
                        context.move(to: CGPoint(x: x, y: Double(rect.minY)))
                        context.addLine(to: CGPoint(x: x, y: Double(rect.minY) + tickHeight))
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

            context.setStrokeColor(AppTheme.Text.muted.cgColor)
            context.setLineWidth(AppTheme.BorderWidth.thin)
            context.move(to: CGPoint(x: x, y: Double(rect.minY)))
            context.addLine(to: CGPoint(x: x, y: Double(rect.minY) + AppTheme.Spacing.smMd))
            context.strokePath()

            let label = formatTimecode(frame: frame, fps: fps)
            let str = NSAttributedString(string: label, attributes: attrs)
            let size = str.size()
            str.draw(at: NSPoint(
                x: x + AppTheme.Spacing.xs,
                y: Double(rect.maxY) - size.height - AppTheme.Spacing.xxs
            ))

            frame += framesPerMajor
        }
    }

    /// Choose a tick interval that keeps major ticks ~80px apart.
    private static func tickInterval(pixelsPerFrame: Double, fps: Int) -> Int {
        let targetPixels = 80.0
        let rawFrames = targetPixels / pixelsPerFrame
        let candidates = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200, 1800, 3600].map { $0 * fps }
        return candidates.first { Double($0) >= rawFrames } ?? candidates.last!
    }

    private static func minorSubdivisions(framesPerMajor: Int, pixelsPerFrame: Double, fps: Int) -> Int {
        let majorPixels = Double(framesPerMajor) * pixelsPerFrame
        for divisions in [20, 10, 5, 4, 2] {
            if majorPixels / Double(divisions) >= AppTheme.Spacing.sm {
                return divisions
            }
        }
        return 0
    }
}
