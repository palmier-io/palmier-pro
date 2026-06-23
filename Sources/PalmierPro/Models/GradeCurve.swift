import CoreImage
import Foundation

struct CurvePoint: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
}

/// Master (Rec.709 luma) + per-channel R/G/B tone curves, compiled to a `CIColorCube`.
struct GradeCurve: Codable, Sendable, Equatable {
    var master: [CurvePoint] = []
    var red: [CurvePoint] = []
    var green: [CurvePoint] = []
    var blue: [CurvePoint] = []

    static let identityPoints = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]

    var isIdentity: Bool {
        [master, red, green, blue].allSatisfy { $0.isEmpty || $0 == Self.identityPoints }
    }

    /// Piecewise-linear interpolation, clamped flat outside the point range.
    static func eval(_ pts: [CurvePoint], _ x: Double) -> Double {
        let p = (pts.isEmpty ? identityPoints : pts).sorted { $0.x < $1.x }
        if x <= p[0].x { return p[0].y }
        if x >= p[p.count - 1].x { return p[p.count - 1].y }
        for i in 1..<p.count where x <= p[i].x {
            let a = p[i - 1], b = p[i]
            let t = (b.x - a.x) == 0 ? 0 : (x - a.x) / (b.x - a.x)
            return a.y + (b.y - a.y) * t
        }
        return x
    }

    func encoded() -> String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// Failable JSON init kept in an extension so the memberwise initializer survives.
extension GradeCurve {
    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(GradeCurve.self, from: data) else { return nil }
        self = decoded
    }
}

