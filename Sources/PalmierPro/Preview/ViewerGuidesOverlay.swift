import SwiftUI

struct ViewerGuidesOverlay: View {
    let activeGuides: Set<ViewerGuide>

    var body: some View {
        Canvas { ctx, size in
            for guide in activeGuides {
                switch guide {
                case .actionSafe, .titleSafe:
                    drawSafeZone(guide, ctx: &ctx, size: size)
                case .center:
                    drawCenter(ctx: &ctx, size: size)
                case .scope, .wide, .square, .portrait:
                    drawFormatBars(guide, ctx: &ctx, size: size)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func drawSafeZone(_ guide: ViewerGuide, ctx: inout GraphicsContext, size: CGSize) {
        guard let inset = guide.safeZoneInset else { return }
        let dx = size.width * inset
        let dy = size.height * inset
        let rect = CGRect(x: dx, y: dy, width: size.width - dx * 2, height: size.height - dy * 2)
        var path = Path()
        path.addRect(rect)
        ctx.stroke(
            path,
            with: .color(.white.opacity(AppTheme.Opacity.strong)),
            style: StrokeStyle(lineWidth: AppTheme.BorderWidth.thin, dash: [4, 3])
        )
    }

    private func drawCenter(ctx: inout GraphicsContext, size: CGSize) {
        let cx = size.width / 2
        let cy = size.height / 2
        let arm: CGFloat = 14
        var path = Path()
        path.move(to: CGPoint(x: cx - arm, y: cy))
        path.addLine(to: CGPoint(x: cx + arm, y: cy))
        path.move(to: CGPoint(x: cx, y: cy - arm))
        path.addLine(to: CGPoint(x: cx, y: cy + arm))
        ctx.stroke(path, with: .color(.white.opacity(AppTheme.Opacity.strong)), lineWidth: AppTheme.BorderWidth.thin)
    }

    private func drawFormatBars(_ guide: ViewerGuide, ctx: inout GraphicsContext, size: CGSize) {
        guard let target = guide.formatAspect else { return }
        let current = size.width / size.height
        guard abs(current - target) > 0.01 else { return }

        let barFill = GraphicsContext.Shading.color(.black.opacity(AppTheme.Opacity.strong))
        let edge = GraphicsContext.Shading.color(.white.opacity(AppTheme.Opacity.medium))

        if target < current {
            // Pillarbox: black bars on left and right
            let innerW = size.height * target
            let barW = (size.width - innerW) / 2
            ctx.fill(Path(CGRect(x: 0, y: 0, width: barW, height: size.height)), with: barFill)
            ctx.fill(Path(CGRect(x: size.width - barW, y: 0, width: barW, height: size.height)), with: barFill)
            var border = Path()
            border.move(to: CGPoint(x: barW, y: 0))
            border.addLine(to: CGPoint(x: barW, y: size.height))
            border.move(to: CGPoint(x: size.width - barW, y: 0))
            border.addLine(to: CGPoint(x: size.width - barW, y: size.height))
            ctx.stroke(border, with: edge, lineWidth: AppTheme.BorderWidth.thin)
        } else {
            // Letterbox: black bars on top and bottom
            let innerH = size.width / target
            let barH = (size.height - innerH) / 2
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: barH)), with: barFill)
            ctx.fill(Path(CGRect(x: 0, y: size.height - barH, width: size.width, height: barH)), with: barFill)
            var border = Path()
            border.move(to: CGPoint(x: 0, y: barH))
            border.addLine(to: CGPoint(x: size.width, y: barH))
            border.move(to: CGPoint(x: 0, y: size.height - barH))
            border.addLine(to: CGPoint(x: size.width, y: size.height - barH))
            ctx.stroke(border, with: edge, lineWidth: AppTheme.BorderWidth.thin)
        }
    }
}
