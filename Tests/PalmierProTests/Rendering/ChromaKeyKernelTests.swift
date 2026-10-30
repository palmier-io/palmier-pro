import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("ChromaKeyKernel")
struct ChromaKeyKernelTests {

    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func solid(_ r: Double, _ g: Double, _ b: Double) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    /// Returns alpha at the pixel after keying green (hue 0.333).
    private func alpha(_ r: Double, _ g: Double, _ b: Double, tolerance: Double = 0.5, spill: Double = 0) -> Double {
        let out = ChromaKeyKernel.apply(solid(r, g, b), keyHue: 0.333, tolerance: tolerance, softness: 0.3, spill: spill)
        var px = [Float](repeating: 0, count: 4)
        ctx.render(out, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBAf, colorSpace: nil)
        return Double(px[3])
    }

    @Test func keysSaturatedGreenTransparent() {
        #expect(alpha(0.1, 0.8, 0.15) < 0.05, "saturated green should key out")
    }

    @Test func keepsOffHueAndDesaturated() {
        #expect(alpha(0.8, 0.2, 0.2) > 0.95, "red stays opaque")
        #expect(alpha(0.7, 0.55, 0.45) > 0.95, "skin tone stays opaque")
        #expect(alpha(0.5, 0.5, 0.5) > 0.95, "gray stays opaque (not saturated)")
        #expect(alpha(0.01, 0.05, 0.015) > 0.95, "near-black chroma noise stays opaque")
    }

    @Test func toleranceZeroIsNoOp() {
        #expect(alpha(0.1, 0.8, 0.15, tolerance: 0) > 0.95, "no key with zero tolerance")
    }

    @Test func spillDesaturatesEdges() {
        // A green-tinted edge pixel (partial key) loses its green cast with spill on.
        let off = ChromaKeyKernel.apply(solid(0.4, 0.6, 0.42), keyHue: 0.333, tolerance: 0.3, softness: 0.5, spill: 0)
        let on = ChromaKeyKernel.apply(solid(0.4, 0.6, 0.42), keyHue: 0.333, tolerance: 0.3, softness: 0.5, spill: 1)
        func g(_ i: CIImage) -> Double {
            var px = [Float](repeating: 0, count: 4)
            ctx.render(i, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
            return Double(px[1] - px[0])  // green excess over red
        }
        #expect(g(on) < g(off), "spill suppression reduces green cast")
    }
}
