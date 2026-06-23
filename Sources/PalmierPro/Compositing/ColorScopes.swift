import CoreImage
import Foundation

/// Quantitative color measurements of a frame
struct Scopes: Sendable {
    var lumaMean: Float
    var lumaBlack: Float        // 2nd percentile
    var lumaWhite: Float        // 98th percentile
    var clipLow: Float          // fraction of pixels with luma < 0.02
    var clipHigh: Float         // fraction with luma > 0.98
    var lumaHistogram: [Float]  // 16 bins, normalized
    var meanRGB: SIMD3<Float>
    var blackRGB: SIMD3<Float>  // per-channel 2nd percentile
    var whiteRGB: SIMD3<Float>  // per-channel 98th percentile
    var shadowRGB: SIMD3<Float> // mean RGB of pixels with luma < 1/3
    var midRGB: SIMD3<Float>
    var highRGB: SIMD3<Float>   // mean RGB of pixels with luma > 2/3
    var saturationMean: Float
    var warmCoolBias: Float     // meanR − meanB  (+ = warm)
    var greenMagentaBias: Float // meanG − (meanR+meanB)/2  (+ = green)
    var hueHistogram: [Float]   // 12 bins of 30° from 0°/red, saturation-weighted, normalized
    var colorfulPct: Float      // fraction of pixels with saturation > 0.15
}

enum ColorScopes {
    static let context = CIContext(options: [
        .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
    ])

    static func measure(_ image: CIImage, gridEdge n: Int = 256) -> Scopes? {
        let extent = image.extent
        guard n > 0, extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else {
            return nil
        }
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(n) / extent.width, y: CGFloat(n) / extent.height))
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        bytes.withUnsafeMutableBytes {
            context.render(scaled, toBitmap: $0.baseAddress!, rowBytes: n * 4,
                           bounds: CGRect(x: 0, y: 0, width: n, height: n),
                           format: .RGBA8, colorSpace: nil)
        }

        let count = n * n
        var rs = [Float](); rs.reserveCapacity(count)
        var gs = [Float](); gs.reserveCapacity(count)
        var bs = [Float](); bs.reserveCapacity(count)
        var ys = [Float](); ys.reserveCapacity(count)
        var sumR: Float = 0, sumG: Float = 0, sumB: Float = 0, sumY: Float = 0, sumSat: Float = 0
        var shadow = SIMD3<Float>.zero, mid = SIMD3<Float>.zero, high = SIMD3<Float>.zero
        var nShadow = 0, nMid = 0, nHigh = 0
        var clipLow = 0, clipHigh = 0
        var hist = [Float](repeating: 0, count: 16)
        var hueHist = [Float](repeating: 0, count: 12)
        var hueWeight: Float = 0, nColorful = 0

        for i in 0..<count {
            let r = Float(bytes[i * 4]) / 255, g = Float(bytes[i * 4 + 1]) / 255, b = Float(bytes[i * 4 + 2]) / 255
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            rs.append(r); gs.append(g); bs.append(b); ys.append(y)
            sumR += r; sumG += g; sumB += b; sumY += y
            let mx = max(r, max(g, b)), mn = min(r, min(g, b))
            let sat: Float = mx > 0 ? (mx - mn) / mx : 0
            sumSat += sat
            if sat > 0.15 {
                nColorful += 1
                let d = mx - mn
                var h: Float = 0
                if d > 1e-6 {
                    if mx == r { h = (g - b) / d } else if mx == g { h = 2 + (b - r) / d } else { h = 4 + (r - g) / d }
                    h /= 6; if h < 0 { h += 1 }
                }
                hueHist[min(11, Int(h * 12))] += sat
                hueWeight += sat
            }
            let px = SIMD3(r, g, b)
            if y < 1.0 / 3 { shadow += px; nShadow += 1 }
            else if y > 2.0 / 3 { high += px; nHigh += 1 }
            else { mid += px; nMid += 1 }
            if y < 0.02 { clipLow += 1 }
            if y > 0.98 { clipHigh += 1 }
            hist[min(15, Int(y * 16))] += 1
        }

        rs.sort(); gs.sort(); bs.sort(); ys.sort()
        let fc = Float(count)
        func pct(_ a: [Float], _ p: Float) -> Float { a[min(a.count - 1, max(0, Int(p * Float(a.count - 1))))] }
        func zone(_ s: SIMD3<Float>, _ c: Int) -> SIMD3<Float> { c > 0 ? s / Float(c) : .zero }
        let meanR = sumR / fc, meanG = sumG / fc, meanB = sumB / fc

        return Scopes(
            lumaMean: sumY / fc,
            lumaBlack: pct(ys, 0.02), lumaWhite: pct(ys, 0.98),
            clipLow: Float(clipLow) / fc, clipHigh: Float(clipHigh) / fc,
            lumaHistogram: hist.map { $0 / fc },
            meanRGB: SIMD3(meanR, meanG, meanB),
            blackRGB: SIMD3(pct(rs, 0.02), pct(gs, 0.02), pct(bs, 0.02)),
            whiteRGB: SIMD3(pct(rs, 0.98), pct(gs, 0.98), pct(bs, 0.98)),
            shadowRGB: zone(shadow, nShadow), midRGB: zone(mid, nMid), highRGB: zone(high, nHigh),
            saturationMean: sumSat / fc,
            warmCoolBias: meanR - meanB,
            greenMagentaBias: meanG - (meanR + meanB) / 2,
            hueHistogram: hueHist.map { hueWeight > 0 ? $0 / hueWeight : 0 },
            colorfulPct: Float(nColorful) / fc
        )
    }
}
