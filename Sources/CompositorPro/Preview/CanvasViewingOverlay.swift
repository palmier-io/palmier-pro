import SwiftUI

struct CanvasOverlaySelection: Equatable {
    var grid: CanvasGridOverlay?
    var guides: Set<CanvasGuideOverlay> = []
    var format: CanvasFormatOverlay?

    var isEmpty: Bool {
        grid == nil && guides.isEmpty && format == nil
    }

    mutating func clear() {
        grid = nil
        guides.removeAll()
        format = nil
    }
}

enum CanvasGridOverlay: Int, CaseIterable, Identifiable {
    case two = 2
    case three = 3
    case four = 4
    case five = 5

    var id: Int { rawValue }

    var label: String {
        "\(rawValue) × \(rawValue)"
    }

    var linePositions: [CGFloat] {
        (1..<rawValue).map { CGFloat($0) / CGFloat(rawValue) }
    }
}

enum CanvasGuideOverlay: String, CaseIterable, Identifiable {
    case actionSafe
    case titleSafe
    case center

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .actionSafe: L10n.key("Action Safe")
        case .titleSafe: L10n.key("Title Safe")
        case .center: L10n.key("Center")
        }
    }

    var safeZoneInset: CGFloat? {
        switch self {
        case .actionSafe: 0.035
        case .titleSafe: 0.05
        case .center: nil
        }
    }
}

enum CanvasFormatOverlay: String, CaseIterable, Identifiable {
    case scope
    case wide
    case square
    case portrait

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .scope: L10n.key("Scope (2.39:1)")
        case .wide: L10n.key("Wide (1.85:1)")
        case .square: L10n.key("Square (1:1)")
        case .portrait: L10n.key("Portrait (9:16)")
        }
    }

    var aspectRatio: CGFloat {
        switch self {
        case .scope: 2.39
        case .wide: 1.85
        case .square: 1
        case .portrait: 9 / 16
        }
    }

    func contentRect(in size: CGSize) -> CGRect {
        CanvasOverlayGeometry.contentRect(aspectRatio: aspectRatio, in: size)
    }
}

enum CanvasOverlayGeometry {
    static func contentRect(aspectRatio: CGFloat, in size: CGSize) -> CGRect {
        guard aspectRatio > 0, size.width > 0, size.height > 0 else { return .zero }
        let canvasAspect = size.width / size.height
        if canvasAspect > aspectRatio {
            let width = size.height * aspectRatio
            return CGRect(
                x: (size.width - width) / 2,
                y: 0,
                width: width,
                height: size.height
            )
        }
        let height = size.width / aspectRatio
        return CGRect(
            x: 0,
            y: (size.height - height) / 2,
            width: size.width,
            height: height
        )
    }

    static func outsideRects(around contentRect: CGRect, in size: CGSize) -> [CGRect] {
        [
            CGRect(x: 0, y: 0, width: size.width, height: contentRect.minY),
            CGRect(x: 0, y: contentRect.maxY, width: size.width, height: size.height - contentRect.maxY),
            CGRect(x: 0, y: contentRect.minY, width: contentRect.minX, height: contentRect.height),
            CGRect(
                x: contentRect.maxX,
                y: contentRect.minY,
                width: size.width - contentRect.maxX,
                height: contentRect.height
            ),
        ].filter { $0.width > 0 && $0.height > 0 }
    }
}

struct CanvasViewingOverlay: View {
    let selection: CanvasOverlaySelection

    var body: some View {
        if !selection.isEmpty {
            Canvas { context, size in
                if let format = selection.format {
                    drawFormatReference(format, context: &context, size: size)
                }
                if let grid = selection.grid {
                    drawGrid(grid, context: &context, size: size)
                }
                for guide in CanvasGuideOverlay.allCases where selection.guides.contains(guide) {
                    if guide == .center {
                        drawCenter(context: &context, size: size)
                    } else {
                        drawSafeZone(guide, context: &context, size: size)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func drawGrid(_ grid: CanvasGridOverlay, context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        for position in grid.linePositions {
            path.move(to: CGPoint(x: size.width * position, y: 0))
            path.addLine(to: CGPoint(x: size.width * position, y: size.height))
            path.move(to: CGPoint(x: 0, y: size.height * position))
            path.addLine(to: CGPoint(x: size.width, y: size.height * position))
        }
        strokeGuide(path, context: &context, opacity: AppTheme.Opacity.prominent)
    }

    private func drawSafeZone(
        _ guide: CanvasGuideOverlay,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        guard let inset = guide.safeZoneInset else { return }
        let dx = size.width * inset
        let dy = size.height * inset
        let rect = CGRect(
            x: dx,
            y: dy,
            width: size.width - dx * 2,
            height: size.height - dy * 2
        )
        let opacity = guide == .titleSafe ? AppTheme.Opacity.prominent : AppTheme.Opacity.medium
        strokeGuide(Path(rect), context: &context, opacity: opacity)
    }

    private func drawCenter(context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let arm = AppTheme.Spacing.lg
        var path = Path()
        path.move(to: CGPoint(x: center.x - arm, y: center.y))
        path.addLine(to: CGPoint(x: center.x + arm, y: center.y))
        path.move(to: CGPoint(x: center.x, y: center.y - arm))
        path.addLine(to: CGPoint(x: center.x, y: center.y + arm))
        strokeGuide(path, context: &context, opacity: AppTheme.Opacity.prominent)
    }

    private func drawFormatReference(
        _ format: CanvasFormatOverlay,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        let contentRect = format.contentRect(in: size)
        let outsideRects = CanvasOverlayGeometry.outsideRects(around: contentRect, in: size)
        guard !outsideRects.isEmpty else { return }
        let fill = GraphicsContext.Shading.color(
            AppTheme.MediaOverlay.backgroundColor.opacity(AppTheme.Opacity.strong)
        )
        for rect in outsideRects {
            context.fill(Path(rect), with: fill)
        }
        strokeGuide(Path(contentRect), context: &context, opacity: AppTheme.Opacity.medium)
    }

    private func strokeGuide(
        _ path: Path,
        context: inout GraphicsContext,
        opacity: Double
    ) {
        context.stroke(
            path,
            with: .color(AppTheme.MediaOverlay.backgroundColor.opacity(AppTheme.Opacity.strong)),
            lineWidth: AppTheme.BorderWidth.thick
        )
        context.stroke(
            path,
            with: .color(AppTheme.MediaOverlay.primaryColor.opacity(opacity)),
            lineWidth: AppTheme.BorderWidth.hairline
        )
    }
}
