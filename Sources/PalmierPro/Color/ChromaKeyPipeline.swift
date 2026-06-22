import CoreImage
import CoreImage.CIFilterBuiltins

/// Pure Core Image chroma-key ("Ultra Key"). The matte and spill suppression are
/// baked into generated `CIColorCube`s — Apple's documented keying approach — so
/// no Metal kernel (and no SwiftPM kernel-compilation flags) is required.
///
/// Ranges (caller clamps): tolerance/softness/spill in 0…100, edgeFeather in points.
enum ChromaKeyPipeline {

    static let cubeSize = 64

    // MARK: Pure matte math (unit-testable without rendering)

    /// Alpha for one source colour: 0 = fully keyed out (transparent), 1 = kept.
    static func matteAlpha(
        r: Double, g: Double, b: Double,
        keyHue: Double, tolerance: Double, softness: Double
    ) -> Double {
        let hsv = rgbToHSV(r: r, g: g, b: b)
        // Greys/near-greys are never keyed — they carry no chroma to match.
        let satGate = smoothstep(0.10, 0.25, hsv.s)
        if satGate <= 0 { return 1 }

        // 100 tolerance ≈ a quarter of the wheel (90°) — wide enough for a green
        // screen's spread, narrow enough to spare skin/other hues.
        let tolHue = (tolerance / 100.0) * 0.25
        let softHue = (softness / 100.0) * 0.20
        let dh = hueDistance(hsv.h, keyHue)

        // removal: 1 inside tolerance, ramps to 0 across the soft band.
        let removal = (1 - smoothstep(tolHue, tolHue + max(softHue, 0.0001), dh)) * satGate
        return 1 - removal
    }

    /// Spill-suppressed colour: pulls residual key cast toward luma near the key hue.
    static func spillCorrect(
        r: Double, g: Double, b: Double,
        keyHue: Double, spill: Double
    ) -> (r: Double, g: Double, b: Double) {
        guard spill > 0 else { return (r, g, b) }
        let hsv = rgbToHSV(r: r, g: g, b: b)
        let proximity = (1 - smoothstep(0.0, 0.25, hueDistance(hsv.h, keyHue))) * smoothstep(0.10, 0.25, hsv.s)
        let amount = (spill / 100.0) * proximity
        guard amount > 0 else { return (r, g, b) }
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return (mix(r, luma, amount), mix(g, luma, amount), mix(b, luma, amount))
    }

    // MARK: Core Image application

    static func apply(
        _ image: CIImage,
        keyR: Double, keyG: Double, keyB: Double,
        tolerance: Double, softness: Double, spill: Double, edgeFeather: Double
    ) -> CIImage {
        let n = cubeSize
        // The cubes depend only on key colour/tolerance/softness/spill, not the frame,
        // so build them once per parameter set and reuse across frames/clips.
        let cubes = cachedCubes(keyR: keyR, keyG: keyG, keyB: keyB,
                                tolerance: tolerance, softness: softness, spill: spill, n: n)
        let fgImage = applyCube(cubes.fg, dimension: n, to: image)
        var matteImage = applyCube(cubes.matte, dimension: n, to: image)

        if edgeFeather > 0 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = matteImage.clampedToExtent()
            blur.radius = Float(edgeFeather)
            matteImage = (blur.outputImage ?? matteImage).cropped(to: image.extent)
        }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = fgImage
        blend.backgroundImage = CIImage(color: .clear).cropped(to: image.extent)
        blend.maskImage = matteImage
        return (blend.outputImage ?? fgImage).cropped(to: image.extent)
    }

    private static func applyCube(_ data: Data, dimension: Int, to image: CIImage) -> CIImage {
        let f = CIFilter.colorCube()
        f.inputImage = image
        f.cubeDimension = Float(dimension)
        f.cubeData = data
        return f.outputImage ?? image
    }

    // MARK: - Cube cache

    private static let cubeCache = ChromaCubeCache()

    private static func cachedCubes(
        keyR: Double, keyG: Double, keyB: Double,
        tolerance: Double, softness: Double, spill: Double, n: Int
    ) -> (fg: Data, matte: Data) {
        let keyHue = rgbToHSV(r: keyR, g: keyG, b: keyB).h
        let key = "\(Int((keyHue * 1000).rounded()))|\(Int(tolerance.rounded()))|\(Int(softness.rounded()))|\(Int(spill.rounded()))|\(n)"
        return cubeCache.get(key) {
            var fg = [Float](repeating: 0, count: n * n * n * 4)
            var matte = [Float](repeating: 0, count: n * n * n * 4)
            var o = 0
            let denom = Double(n - 1)
            for bi in 0..<n {
                let b = Double(bi) / denom
                for gi in 0..<n {
                    let g = Double(gi) / denom
                    for ri in 0..<n {
                        let r = Double(ri) / denom
                        let a = matteAlpha(r: r, g: g, b: b, keyHue: keyHue, tolerance: tolerance, softness: softness)
                        let c = spillCorrect(r: r, g: g, b: b, keyHue: keyHue, spill: spill)
                        fg[o] = Float(c.r); fg[o + 1] = Float(c.g); fg[o + 2] = Float(c.b); fg[o + 3] = 1
                        let af = Float(a)
                        matte[o] = af; matte[o + 1] = af; matte[o + 2] = af; matte[o + 3] = af
                        o += 4
                    }
                }
            }
            return (fg.withUnsafeBufferPointer { Data(buffer: $0) },
                    matte.withUnsafeBufferPointer { Data(buffer: $0) })
        }
    }
}

/// Small thread-safe LRU-ish cache for generated chroma-key cubes.
private final class ChromaCubeCache: @unchecked Sendable {
    private var store: [String: (fg: Data, matte: Data)] = [:]
    private var order: [String] = []
    private let lock = NSLock()
    private let limit = 12

    func get(_ key: String, build: () -> (fg: Data, matte: Data)) -> (fg: Data, matte: Data) {
        lock.lock()
        defer { lock.unlock() }
        if let cached = store[key] { return cached }
        let built = build()
        store[key] = built
        order.append(key)
        if order.count > limit { store.removeValue(forKey: order.removeFirst()) }
        return built
    }
}

// MARK: - Colour helpers

private func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
    let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}

/// Shortest distance between two hues on the 0…1 colour wheel (0…0.5).
private func hueDistance(_ a: Double, _ b: Double) -> Double {
    let d = abs(a - b).truncatingRemainder(dividingBy: 1)
    return min(d, 1 - d)
}

func rgbToHSV(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
    let maxC = max(r, g, b)
    let minC = min(r, g, b)
    let delta = maxC - minC
    let v = maxC
    let s = maxC == 0 ? 0 : delta / maxC
    var h = 0.0
    if delta != 0 {
        if maxC == r {
            h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == g {
            h = (b - r) / delta + 2
        } else {
            h = (r - g) / delta + 4
        }
        h /= 6
        if h < 0 { h += 1 }
    }
    return (h, s, v)
}
