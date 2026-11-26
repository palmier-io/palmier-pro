import CoreGraphics
import Foundation

struct MapSceneSymbols {
    private let paths: [MapSceneObjectKind: CGPath]
    private let details: [MapSceneObjectKind: CGPath]

    init() {
        func polygon(_ points: [(Double, Double)]) -> CGPath {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: points[0].0, y: points[0].1))
            for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
            path.closeSubpath()
            return path
        }
        func lines(_ pairs: [[(Double, Double)]]) -> CGPath {
            let path = CGMutablePath()
            for pair in pairs {
                path.move(to: CGPoint(x: pair[0].0, y: pair[0].1))
                for point in pair.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
            }
            return path
        }
        let person = CGMutablePath()
        person.addEllipse(in: CGRect(x: -0.12, y: -0.5, width: 0.24, height: 0.24))
        person.addPath(polygon([(-0.12, -0.2), (0.12, -0.2), (0.26, 0.12), (0.14, 0.17),
            (0.09, 0.02), (0.12, 0.48), (0, 0.48), (-0.04, 0.16), (-0.1, 0.48),
            (-0.22, 0.48), (-0.15, 0.02), (-0.26, 0.17), (-0.34, 0.08)]))
        let pin = CGMutablePath()
        pin.addEllipse(in: CGRect(x: -0.25, y: -0.5, width: 0.5, height: 0.5))
        pin.addPath(polygon([(-0.2, -0.12), (0.2, -0.12), (0, 0.45)]))
        paths = [
            .ship: polygon([(-0.48, 0.02), (-0.35, 0.27), (0.28, 0.27), (0.5, 0.02),
                (0.3, -0.02), (0.3, -0.17), (0.05, -0.17), (0.05, -0.32),
                (-0.16, -0.32), (-0.16, -0.15), (-0.4, -0.15), (-0.4, 0.02)]),
            .airplane: polygon([(0.5, 0), (0.32, 0.07), (0.06, 0.07), (-0.2, 0.45),
                (-0.32, 0.45), (-0.15, 0.06), (-0.36, 0.06), (-0.45, 0.18),
                (-0.5, 0.18), (-0.46, 0), (-0.5, -0.18), (-0.45, -0.18),
                (-0.36, -0.06), (-0.15, -0.06), (-0.32, -0.45), (-0.2, -0.45),
                (0.06, -0.07), (0.32, -0.07)]),
            .truck: polygon([(-0.48, -0.32), (0.12, -0.32), (0.12, -0.2), (0.35, -0.2),
                (0.5, 0.02), (0.5, 0.23), (-0.48, 0.23)]),
            .train: polygon([(-0.48, -0.25), (0.35, -0.25), (0.48, -0.06),
                (0.48, 0.25), (-0.48, 0.25)]),
            .package: polygon([(0, -0.43), (0.43, -0.2), (0.43, 0.25), (0, 0.48),
                (-0.43, 0.25), (-0.43, -0.2)]),
            .person: person,
            .factory: polygon([(-0.48, 0.4), (-0.48, -0.08), (-0.18, -0.27), (-0.18, -0.08),
                (0.12, -0.27), (0.12, -0.08), (0.25, -0.08), (0.25, -0.5),
                (0.4, -0.5), (0.4, 0.4)]),
            .tank: polygon([(-0.5, 0.28), (-0.5, 0.05), (-0.3, -0.06), (-0.22, -0.26),
                (0.16, -0.26), (0.22, -0.13), (0.5, -0.13), (0.5, -0.05),
                (0.2, -0.05), (0.35, 0.05), (0.48, 0.12), (0.48, 0.28)]),
            .arrow: polygon([(-0.5, -0.1), (0.15, -0.1), (0.15, -0.3), (0.5, 0),
                (0.15, 0.3), (0.15, 0.1), (-0.5, 0.1)]),
            .circle: CGPath(ellipseIn: CGRect(x: -0.4, y: -0.4, width: 0.8, height: 0.8), transform: nil),
            .money: CGPath(ellipseIn: CGRect(x: -0.43, y: -0.43, width: 0.86, height: 0.86), transform: nil),
            .pin: pin,
        ]
        details = [
            .ship: lines([[(-0.35, -0.02), (0.3, -0.02)], [(-0.1, -0.27), (-0.02, -0.27)],
                [(-0.5, 0.38), (-0.23, 0.42), (0.03, 0.37), (0.35, 0.42), (0.5, 0.38)]]),
            .package: lines([[(-0.43, -0.2), (0, 0.03), (0.43, -0.2)], [(0, 0.03), (0, 0.48)],
                [(-0.22, -0.32), (0.22, -0.09), (0.22, 0.05)]]),
            .truck: lines([[(0.2, -0.15), (0.34, -0.15), (0.41, -0.03), (0.2, -0.03), (0.2, -0.15)],
                [(-0.27, 0.16), (-0.27, 0.34)], [(0.3, 0.16), (0.3, 0.34)]]),
            .train: lines([[(-0.35, -0.13), (-0.23, -0.13)], [(-0.12, -0.13), (0, -0.13)],
                [(0.1, -0.13), (0.22, -0.13)], [(-0.36, 0.16), (-0.36, 0.33)],
                [(-0.1, 0.16), (-0.1, 0.33)], [(0.2, 0.16), (0.2, 0.33)]]),
            .factory: lines([[(-0.36, 0.12), (-0.25, 0.12)], [(-0.13, 0.12), (-0.02, 0.12)],
                [(0.1, 0.12), (0.2, 0.12)]]),
            .tank: lines([[(-0.38, 0.2), (0.37, 0.2)]]),
            .money: lines([[(0.16, -0.18), (-0.08, -0.22), (-0.17, -0.1), (0.15, 0.1),
                (0.05, 0.22), (-0.17, 0.18)], [(0, -0.32), (0, 0.32)]]),
        ]
    }

    func draw(_ kind: MapSceneObjectKind, context: CGContext, color: CGColor, elapsed: Double, progress: Double, opacity: Double) {
        if let path = paths[kind] {
            context.addPath(path)
            context.drawPath(using: .fillStroke)
            if let detail = details[kind] {
                context.addPath(detail)
                context.strokePath()
            }
            return
        }
        context.setShadow(offset: .zero, blur: 0.08, color: color)
        switch kind {
        case .gunfire, .explosion:
            let phase = kind == .gunfire ? (elapsed * 7).truncatingRemainder(dividingBy: 1) : progress
            let radius = kind == .gunfire ? 0.24 + 0.24 * (1 - phase) : 0.15 + 0.7 * phase
            context.setAlpha(opacity * (kind == .gunfire ? 1 - phase * 0.75 : max(0, 1 - phase)))
            context.move(to: CGPoint(x: radius, y: 0))
            for index in 1...16 {
                let angle = Double(index) * .pi / 8
                let r = index.isMultiple(of: 2) ? radius : radius * 0.36
                context.addLine(to: CGPoint(x: cos(angle) * r, y: sin(angle) * r))
            }
            context.closePath()
            context.fillPath()
        case .rain:
            context.setStrokeColor(color)
            context.setLineWidth(0.025)
            for index in 0..<16 {
                let x = Double(index % 4) * 0.26 - 0.4
                let y = (Double(index / 4) * 0.25 + elapsed * 0.9).truncatingRemainder(dividingBy: 1) - 0.5
                context.move(to: CGPoint(x: x, y: y))
                context.addLine(to: CGPoint(x: x - 0.06, y: y + 0.16))
            }
            context.strokePath()
        case .heat:
            for index in 0..<5 {
                let phase = (elapsed * 0.5 + Double(index) * 0.2).truncatingRemainder(dividingBy: 1)
                context.setAlpha(opacity * (1 - phase))
                context.fillEllipse(in: CGRect(x: Double(index) * 0.17 - 0.36 + sin(elapsed * 3 + Double(index)) * 0.06,
                    y: 0.4 - phase, width: 0.08, height: 0.25))
            }
        default: break
        }
    }
}
