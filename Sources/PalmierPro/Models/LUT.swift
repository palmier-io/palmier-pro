import CoreImage
import Foundation

protocol ColorGradeProcessor: Sendable {
    func process(_ image: CIImage, colorSpace: CGColorSpace) -> CIImage
}

/// Project color grade: a built-in look or an inline-embedded `.cube` (RGBA float32
/// base64). Embedded so the grade is portable with the project; `get_timeline` drops
/// `cubeBase64` so the blob never reaches agent context.
struct LUTRef: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case look, cube }

    var kind: Kind
    var lookID: String?
    var cubeName: String?
    var cubeDimension: Int?
    var cubeBase64: String?
    var intensity: Double = 1.0

    var clampedIntensity: Double { min(1.0, max(0.0, intensity)) }

    static func look(_ id: String, intensity: Double = 1.0) -> LUTRef {
        LUTRef(kind: .look, lookID: id, intensity: intensity)
    }

    static func cube(_ lut: CubeLUT, name: String, intensity: Double = 1.0) -> LUTRef {
        LUTRef(kind: .cube, cubeName: name, cubeDimension: lut.dimension,
               cubeBase64: lut.base64, intensity: intensity)
    }

    func makeProcessor() -> ColorGradeProcessor? {
        switch kind {
        case .look:
            return lookID.flatMap { ColorGradeCatalog.look(id: $0) }
        case .cube:
            guard let dim = cubeDimension, let b64 = cubeBase64 else { return nil }
            return CubeLUT(base64: b64, dimension: dim)
        }
    }

    /// Compact form for `get_timeline` — never includes the cube blob.
    var summary: [String: Any] {
        var out: [String: Any] = ["kind": kind.rawValue, "intensity": clampedIntensity]
        switch kind {
        case .look: if let lookID { out["look"] = lookID }
        case .cube:
            if let cubeName { out["cube"] = cubeName }
            if let cubeDimension { out["dimension"] = cubeDimension }
        }
        return out
    }
}
