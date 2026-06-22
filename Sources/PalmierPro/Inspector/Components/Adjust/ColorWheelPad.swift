import SwiftUI

/// A circular hue/saturation pad. Position is value-space `(x, y)` in the unit disk,
/// y pointing up; the puck color and the grade share `ColorWheels` so they always agree.
struct ColorWheelPad: View {
    let x: Double
    let y: Double
    let onChanged: (Double, Double) -> Void
    let onCommit: (Double, Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            let center = CGPoint(x: radius, y: radius)
            ZStack {
                Image(decorative: wheelImage, scale: 1)
                    .resizable()
                    .clipShape(Circle())
                crosshair(size: size, radius: radius)
                Circle().strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.Wheels.ringWidth)
                puck
                    .position(x: center.x + CGFloat(x) * radius, y: center.y - CGFloat(y) * radius)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .onTapGesture(count: 2) { onCommit(0, 0) }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { let p = point(at: $0.location, center: center, radius: radius); onChanged(p.0, p.1) }
                    .onEnded { let p = point(at: $0.location, center: center, radius: radius); onCommit(p.0, p.1) }
            )
        }
        .frame(width: AppTheme.Wheels.padSize, height: AppTheme.Wheels.padSize)
    }

    private var puck: some View {
        Circle()
            .fill(.white)
            .frame(width: AppTheme.Wheels.puckSize, height: AppTheme.Wheels.puckSize)
            .overlay(Circle().strokeBorder(AppTheme.Background.baseColor, lineWidth: AppTheme.BorderWidth.thin))
            .shadow(AppTheme.Shadow.sm)
    }

    private func crosshair(size: CGFloat, radius: CGFloat) -> some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: radius)); p.addLine(to: CGPoint(x: size, y: radius))
            p.move(to: CGPoint(x: radius, y: 0)); p.addLine(to: CGPoint(x: radius, y: size))
        }
        .stroke(AppTheme.Wheels.crosshairColor, lineWidth: AppTheme.BorderWidth.hairline)
        .clipShape(Circle())
    }

    private func point(at loc: CGPoint, center: CGPoint, radius: CGFloat) -> (Double, Double) {
        var vx = Double(loc.x - center.x) / Double(radius)
        var vy = Double(center.y - loc.y) / Double(radius)
        let mag = (vx * vx + vy * vy).squareRoot()
        if mag > 1 { vx /= mag; vy /= mag }
        return (vx, vy)
    }
}

/// Built once and shared by every pad — neutral gray center fading to saturated hue at the rim.
private let wheelImage: CGImage = {
    let d = 160
    let c = Double(d) / 2
    func byte(_ v: Double) -> UInt8 { UInt8(min(255, max(0, v * 255))) }
    var px = [UInt8](repeating: 0, count: d * d * 4)
    for j in 0..<d {
        for i in 0..<d {
            let vx = (Double(i) - c) / c
            let vy = (c - Double(j)) / c
            let r = (vx * vx + vy * vy).squareRoot()
            guard r <= 1.02 else { continue }
            let (cr, cg, cb) = ColorWheels.displayColor(x: vx, y: vy)
            let a = r <= 1 ? 1 : max(0, 1 - (r - 1) / 0.02)
            let o = (j * d + i) * 4
            px[o] = byte(cr * a); px[o + 1] = byte(cg * a); px[o + 2] = byte(cb * a); px[o + 3] = byte(a)
        }
    }
    let ctx = CGContext(
        data: &px, width: d, height: d, bitsPerComponent: 8, bytesPerRow: d * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return ctx.makeImage()!
}()
