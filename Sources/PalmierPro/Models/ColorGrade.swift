import CoreImage
import Foundation

struct CurvePoint: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
}

/// Master + per-channel tone curves, compiled to a CubeLUT (identity when diagonal).
struct GradeCurve: Codable, Sendable, Equatable {
    var master: [CurvePoint] = []
    var red: [CurvePoint] = []
    var green: [CurvePoint] = []
    var blue: [CurvePoint] = []

    static let identityPoints = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]

    var isIdentity: Bool {
        [master, red, green, blue].allSatisfy { $0.isEmpty || $0 == Self.identityPoints }
    }

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

    func cube(dimension n: Int = 17) -> CubeLUT {
        func clamp(_ v: Double) -> Float { Float(min(1, max(0, v))) }
        var table = [Float]()
        table.reserveCapacity(n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let rf = Double(r) / Double(n - 1)
                    let gf = Double(g) / Double(n - 1)
                    let bf = Double(b) / Double(n - 1)
                    table.append(clamp(Self.eval(red, Self.eval(master, rf))))
                    table.append(clamp(Self.eval(green, Self.eval(master, gf))))
                    table.append(clamp(Self.eval(blue, Self.eval(master, bf))))
                    table.append(1)
                }
            }
        }
        return CubeLUT(dimension: n, rgbaTable: table, domainMin: SIMD3(0, 0, 0), domainMax: SIMD3(1, 1, 1))
    }
}

/// Project-wide primary color correction. All controls are −100…100 with 0 = identity.
struct PrimaryGrade: Codable, Sendable, Equatable {
    var temperature = 0.0
    var tint = 0.0
    var exposure = 0.0
    var contrast = 0.0
    var saturation = 0.0
    var vibrance = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var curve: GradeCurve?

    var isIdentity: Bool {
        temperature == 0 && tint == 0 && exposure == 0 && contrast == 0
            && saturation == 0 && vibrance == 0 && highlights == 0 && shadows == 0
            && (curve?.isIdentity ?? true)
    }

    /// Filters in correction order: WB → exposure → contrast/sat → vibrance → highlights/shadows → curves.
    func ciFilters() -> [CIFilter] {
        var out: [CIFilter] = []

        if temperature != 0 || tint != 0, let f = CIFilter(name: "CITemperatureAndTint") {
            f.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            f.setValue(CIVector(x: 6500 - temperature * 15, y: tint * 15), forKey: "inputTargetNeutral")
            out.append(f)
        }
        if exposure != 0, let f = CIFilter(name: "CIExposureAdjust") {
            f.setValue(exposure / 50.0, forKey: "inputEV")   // ±100 → ±2 EV
            out.append(f)
        }
        if contrast != 0 || saturation != 0, let f = CIFilter(name: "CIColorControls") {
            f.setValue(1 + contrast / 100.0, forKey: "inputContrast")
            f.setValue(1 + saturation / 100.0, forKey: "inputSaturation")
            out.append(f)
        }
        if vibrance != 0, let f = CIFilter(name: "CIVibrance") {
            f.setValue(vibrance / 100.0, forKey: "inputAmount")
            out.append(f)
        }
        if (highlights != 0 || shadows != 0), let f = CIFilter(name: "CIToneCurve") {
            let s = shadows / 500.0       // ±100 → ±0.2
            let h = highlights / 500.0
            f.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
            f.setValue(CIVector(x: 0.25, y: max(0, 0.25 + s)), forKey: "inputPoint1")
            f.setValue(CIVector(x: 0.5, y: 0.5), forKey: "inputPoint2")
            f.setValue(CIVector(x: 0.75, y: min(1, 0.75 + h)), forKey: "inputPoint3")
            f.setValue(CIVector(x: 1, y: 1), forKey: "inputPoint4")
            out.append(f)
        }
        if let curve, !curve.isIdentity,
           let f = curve.cube().makeFilter(colorSpace: GradePipeline.workingColorSpace) {
            out.append(f)
        }
        return out
    }
}

/// Applies a prebuilt CIFilter chain — the shared processor for preview and export.
/// `@unchecked Sendable`: the chain is used single-threaded (one export pass / main-thread preview).
struct FilterChainProcessor: ColorGradeProcessor, @unchecked Sendable {
    let filters: [CIFilter]
    func process(_ image: CIImage, colorSpace: CGColorSpace) -> CIImage {
        var result = image
        for f in filters {
            f.setValue(result, forKey: kCIInputImageKey)
            if let out = f.outputImage { result = out }
        }
        return result
    }
}

/// Full grade filter chain (primaries → LUT/look) shared by live preview and export.
enum GradePipeline {
    static let workingColorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    static func filters(primaries: PrimaryGrade?, lut: LUTRef?) -> [CIFilter] {
        var out: [CIFilter] = []
        if let primaries, !primaries.isIdentity { out += primaries.ciFilters() }
        if let lut, lut.clampedIntensity > 0 { out += lutFilters(lut) }
        return out
    }

    static func lutFilters(_ lut: LUTRef) -> [CIFilter] {
        let t = lut.clampedIntensity
        switch lut.kind {
        case .look:
            return lut.lookID.flatMap(ColorGradeCatalog.look(id:))?.ciFilters(intensity: t) ?? []
        case .cube:
            guard let dim = lut.cubeDimension, let b64 = lut.cubeBase64,
                  let cube = CubeLUT(base64: b64, dimension: dim) else { return [] }
            return cube.intensityBlended(t).makeFilter(colorSpace: workingColorSpace).map { [$0] } ?? []
        }
    }
}
