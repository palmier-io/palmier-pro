import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("GradeCurveKernel")
struct GradeCurveKernelTests {

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

    @Test func identityIsPassthrough() {
        #expect(d(sample(GradeCurveKernel.apply(solid(0.6, 0.3, 0.8), curve: GradeCurve())), (0.6, 0.3, 0.8)) < 1e-4)
    }

    @Test func channelCurveTouchesOnlyThatChannel() {
        var c = GradeCurve()
        c.red = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.8), CurvePoint(x: 1, y: 1)]
        let out = sample(GradeCurveKernel.apply(solid(0.5, 0.5, 0.5), curve: c))
        #expect(out.0 > 0.7, "red 0.5→0.8, got \(out)")
        #expect(abs(out.1 - 0.5) < 0.02 && abs(out.2 - 0.5) < 0.02, "green/blue untouched, got \(out)")
    }

    @Test func masterLiftBrightensNeutrally() {
        var c = GradeCurve()
        c.master = [CurvePoint(x: 0, y: 0.3), CurvePoint(x: 1, y: 1)]
        let out = sample(GradeCurveKernel.apply(solid(0.3, 0.3, 0.3), curve: c))
        #expect(out.0 > 0.4, "shadows lifted, got \(out)")
        #expect(abs(out.0 - out.1) < 0.01 && abs(out.1 - out.2) < 0.01, "stays neutral, got \(out)")
    }

    @Test func shadowLiftDoesNotBlowOutDarkSaturated() {
        // A floor-lifting master curve on a near-black saturated pixel: uncapped, the gain
        // (yp/y ≈ 25x) would blow the red channel to ~1; the capped gain keeps it bounded.
        var c = GradeCurve()
        c.master = [CurvePoint(x: 0, y: 0.3), CurvePoint(x: 1, y: 1)]
        let out = sample(GradeCurveKernel.apply(solid(0.04, 0.005, 0.005), curve: c))
        #expect(out.0 < 0.5, "dark red shouldn't blow out, got \(out)")
    }

    @Test func steepCurveStaysSmooth() {
        // Per-pixel eval of a steep curve has none of the 17³ cube's node-boundary steps.
        var c = GradeCurve()
        c.master = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.9), CurvePoint(x: 1, y: 1)]
        var prev: (Double, Double, Double)?
        var maxJump = 0.0
        for i in 0...255 {
            let v = Double(i) / 255
            let out = sample(GradeCurveKernel.apply(solid(v, v, v), curve: c))
            if let prev { maxJump = max(maxJump, d(out, prev)) }
            prev = out
        }
        #expect(maxJump < 0.03, "smooth per-pixel curve, max step \(maxJump)")
    }
}
