import Foundation

/// A parsed Adobe `.cube` LUT, ready for `CIColorCube`.
///
/// `rgbaData` is row-major with the **red index varying fastest**, then green,
/// then blue — the ordering both the `.cube` spec and `CIColorCube` expect — so a
/// 3D table copies straight through with an appended `a = 1`.
struct CubeLUT: Equatable, Sendable {
    /// Edge length of the 3D table (entries = size³).
    let size: Int
    /// `size³ × 4` floats, channel order RGBA, values clamped to 0…1.
    let rgbaData: [Float]

    struct ParseError: LocalizedError, Equatable {
        let reason: String
        var errorDescription: String? { "Invalid .cube LUT: \(reason)" }
    }

    /// `NSData` payload for `CIColorCube.inputCubeData`.
    var cubeData: Data {
        rgbaData.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func parse(contentsOf url: URL) throws -> CubeLUT {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    static func parse(_ text: String) throws -> CubeLUT {
        var size3D: Int?
        var size1D: Int?
        var triples: [(Float, Float, Float)] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let keyword = fields.first else { continue }

            switch keyword.uppercased() {
            case "TITLE", "DOMAIN_MIN", "DOMAIN_MAX":
                continue // metadata we don't need; 0…1 domain assumed
            case "LUT_3D_SIZE":
                guard fields.count >= 2, let n = Int(fields[1]), n >= 2, n <= 256 else {
                    throw ParseError(reason: "bad LUT_3D_SIZE")
                }
                size3D = n
            case "LUT_1D_SIZE":
                guard fields.count >= 2, let n = Int(fields[1]), n >= 2, n <= 65536 else {
                    throw ParseError(reason: "bad LUT_1D_SIZE")
                }
                size1D = n
            default:
                guard fields.count >= 3,
                      let r = Float(fields[0]), let g = Float(fields[1]), let b = Float(fields[2]) else {
                    throw ParseError(reason: "malformed data row '\(line)'")
                }
                triples.append((r, g, b))
            }
        }

        if let n = size3D {
            guard triples.count == n * n * n else {
                throw ParseError(reason: "expected \(n * n * n) rows for 3D size \(n), got \(triples.count)")
            }
            var data = [Float](repeating: 0, count: n * n * n * 4)
            for (i, t) in triples.enumerated() {
                let o = i * 4
                data[o] = clamp01(t.0); data[o + 1] = clamp01(t.1)
                data[o + 2] = clamp01(t.2); data[o + 3] = 1
            }
            return CubeLUT(size: n, rgbaData: data)
        }

        if let n = size1D {
            guard triples.count == n else {
                throw ParseError(reason: "expected \(n) rows for 1D size \(n), got \(triples.count)")
            }
            return expand1D(curve: triples, size: n)
        }

        throw ParseError(reason: "missing LUT_3D_SIZE / LUT_1D_SIZE")
    }

    /// Promote a 1D per-channel curve into a 3D cube: out = (curve[r].r, curve[g].g, curve[b].b).
    private static func expand1D(curve: [(Float, Float, Float)], size n: Int) -> CubeLUT {
        var data = [Float](repeating: 0, count: n * n * n * 4)
        var o = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    data[o] = clamp01(curve[r].0)
                    data[o + 1] = clamp01(curve[g].1)
                    data[o + 2] = clamp01(curve[b].2)
                    data[o + 3] = 1
                    o += 4
                }
            }
        }
        return CubeLUT(size: n, rgbaData: data)
    }
}

private func clamp01(_ v: Float) -> Float { min(1, max(0, v)) }
