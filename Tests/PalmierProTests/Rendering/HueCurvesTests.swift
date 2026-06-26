import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("HueCurves")
struct HueCurvesTests {

    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func solid(_ r: Double, _ g: Double, _ b: Double) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    private func sample(_ image: CIImage) -> (Double, Double, Double) {
        var px = [Float](repeating: 0, count: 4)
        ctx.render(image, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBAf, colorSpace: nil)
        return (Double(px[0]), Double(px[1]), Double(px[2]))
    }

    private func d(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        max(abs(a.0 - b.0), max(abs(a.1 - b.1), abs(a.2 - b.2)))
    }

    /// Push only the red band of Hue-vs-Hue; everything else holds at neutral.
    private var redOnly: HueCurves {
        var c = HueCurves()
        c.hueVsHue = [
            CurvePoint(x: 0, y: 0.8), CurvePoint(x: 1.0 / 6, y: 0.5), CurvePoint(x: 2.0 / 6, y: 0.5),
            CurvePoint(x: 3.0 / 6, y: 0.5), CurvePoint(x: 4.0 / 6, y: 0.5), CurvePoint(x: 5.0 / 6, y: 0.5),
        ]
        return c
    }

    @Test func identityIsNoOp() {
        let img = solid(0.8, 0.3, 0.1)
        #expect(d(sample(HueCurveKernel.apply(img, curves: HueCurves())), (0.8, 0.3, 0.1)) < 1e-4)
    }

    @Test func redBandRotatesRedLeavesBlue() {
        let red = sample(HueCurveKernel.apply(solid(1, 0, 0), curves: redOnly))
        #expect(red.1 > 0.1, "red should rotate toward orange (G rises), got \(red)")
        let blue = sample(HueCurveKernel.apply(solid(0.1, 0.15, 0.9), curves: redOnly))
        #expect(d(blue, (0.1, 0.15, 0.9)) < 0.03, "blue must stay put, got \(blue)")
    }

    @Test func graysAreNeverTinted() {
        // Saturate/rotate everything; achromatic pixels stay achromatic.
        var c = HueCurves()
        let pushed = (0..<6).map { CurvePoint(x: Double($0) / 6, y: 1.0) }
        c.hueVsHue = pushed; c.hueVsSat = pushed; c.hueVsLum = pushed
        for v in [0.2, 0.5, 0.8] {
            let out = sample(HueCurveKernel.apply(solid(v, v, v), curves: c))
            #expect(d(out, (v, v, v)) < 0.02, "gray \(v) tinted → \(out)")
        }
    }

    private func makeCG(_ w: Int, _ h: Int, _ color: (Int, Int) -> (Double, Double, Double)) -> CGImage {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let c = color(x, y); let i = (y * w + x) * 4
                px[i] = UInt8(c.0 * 255); px[i + 1] = UInt8(c.1 * 255); px[i + 2] = UInt8(c.2 * 255); px[i + 3] = 255
            }
        }
        let ctx = px.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        return ctx!.makeImage()!
    }

    @Test func hueHistogramPeaksAtPresentHues() {
        // Left half red, right half blue → humps at hue 0 and ~0.67, nothing in the greens.
        let cg = makeCG(64, 16) { x, _ in x < 32 ? (0.9, 0.1, 0.1) : (0.1, 0.15, 0.9) }
        let bins = VideoEngine.hueHistogram(from: cg, count: 96)!
        let red = bins[0...2].max() ?? 0
        let blue = bins[60...66].max() ?? 0
        let green = bins[28...40].max() ?? 0
        #expect(red > 0.5 && blue > 0.5, "red \(red) blue \(blue)")
        #expect(green < 0.05, "greens should be empty, got \(green)")
    }

    @Test func hueHistogramIgnoresGray() {
        let cg = makeCG(32, 32) { _, _ in (0.5, 0.5, 0.5) }
        let bins = VideoEngine.hueHistogram(from: cg, count: 96)!
        #expect(bins.allSatisfy { $0 == 0 }, "achromatic frame should produce no hue data")
    }

    @Test func cyclicEvalIsSeamlessAtHueWrap() {
        // Value just past the last point wraps toward the first — no jump across the seam.
        let pts = [CurvePoint(x: 0, y: 0.9), CurvePoint(x: 5.0 / 6, y: 0.2)]
        let nearOne = HueCurves.eval(pts, 0.999)
        let atZero = HueCurves.eval(pts, 0.0)
        #expect(abs(nearOne - atZero) < 0.05, "seam discontinuity \(nearOne) vs \(atZero)")
    }
}
