import Foundation

/// Resolve-style hue curves: each maps source hue (0…1, cyclic) to one adjustment
struct HueCurves: Codable, Sendable, Equatable {
    var hueVsHue: [CurvePoint] = []   // → hue rotation
    var hueVsSat: [CurvePoint] = []   // → saturation scale
    var hueVsLum: [CurvePoint] = []   // → luminance shift

    enum Channel: String, CaseIterable, Identifiable, Sendable {
        case hue = "Hue", sat = "Sat", lum = "Luma"
        var id: String { rawValue }
    }

    static let neutralY = 0.5
    static let effectType = "color.hueCurves"
    static let defaultPoints: [CurvePoint] = (0..<6).map { CurvePoint(x: Double($0) / 6, y: neutralY) }

    func points(_ c: Channel) -> [CurvePoint] {
        switch c { case .hue: hueVsHue; case .sat: hueVsSat; case .lum: hueVsLum }
    }

    mutating func set(_ c: Channel, _ pts: [CurvePoint]) {
        switch c { case .hue: hueVsHue = pts; case .sat: hueVsSat = pts; case .lum: hueVsLum = pts }
    }

    static func isNeutral(_ pts: [CurvePoint]) -> Bool {
        pts.isEmpty || pts.allSatisfy { abs($0.y - neutralY) < 1e-4 }
    }

    /// All curves flat → no effect to render or persist.
    var isIdentity: Bool { [hueVsHue, hueVsSat, hueVsLum].allSatisfy(Self.isNeutral) }

    /// Cyclic piecewise-linear eval — wraps across the hue seam so the curve is seamless at 0/1.
    static func eval(_ pts: [CurvePoint], _ x: Double) -> Double {
        let p = (pts.isEmpty ? defaultPoints : pts).sorted { $0.x < $1.x }
        guard let first = p.first, let last = p.last else { return neutralY }
        if x < first.x { return lerp(CurvePoint(x: last.x - 1, y: last.y), first, x) }
        for i in 1..<p.count where x <= p[i].x { return lerp(p[i - 1], p[i], x) }
        return lerp(last, CurvePoint(x: first.x + 1, y: first.y), x)
    }

    private static func lerp(_ a: CurvePoint, _ b: CurvePoint, _ x: Double) -> Double {
        let t = (b.x - a.x) == 0 ? 0 : (x - a.x) / (b.x - a.x)
        return a.y + (b.y - a.y) * t
    }

    func encoded() -> String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    init() {}

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(HueCurves.self, from: data) else { return nil }
        self = decoded
    }

    static func read(from effects: [Effect]) -> HueCurves {
        guard let json = effects.first(where: { $0.type == effectType })?.params["curves"]?.string
        else { return HueCurves() }
        return HueCurves(json: json) ?? HueCurves()
    }

    /// Write `self` into `effects` (canonical order), or remove it when there's nothing to keep.
    func upsert(into effects: inout [Effect]) {
        let existing = effects.firstIndex { $0.type == Self.effectType }
        guard !isIdentity, let json = encoded() else {
            if let existing { effects.remove(at: existing) }
            return
        }
        if let existing {
            effects[existing].params["curves"] = EffectParam(string: json)
        } else {
            var effect = Effect(type: Self.effectType)
            effect.params["curves"] = EffectParam(string: json)
            effects.insert(effect, at: EffectRegistry.insertIndex(effects, for: Self.effectType))
        }
    }
}
