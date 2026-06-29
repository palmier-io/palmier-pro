import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("LumaKeyKernel")
struct LumaKeyKernelTests {

    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func solid(_ r: Double, _ g: Double, _ b: Double) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    private func alpha(_ r: Double, _ g: Double, _ b: Double, threshold: Double = 0.9, softness: Double = 0.08) -> Double {
        let out = LumaKeyKernel.apply(solid(r, g, b), threshold: threshold, softness: softness)
        var px = [Float](repeating: 0, count: 4)
        ctx.render(out, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBAf, colorSpace: nil)
        return Double(px[3])
    }

    @Test func keysWhiteTransparent() {
        #expect(alpha(1, 1, 1) < 0.05, "white background should key out")
    }

    @Test func keepsMidtonesAndDarksOpaque() {
        #expect(alpha(0.5, 0.5, 0.5) > 0.95, "mid gray should stay opaque")
        #expect(alpha(0.1, 0.2, 0.3) > 0.95, "dark colored subject should stay opaque")
    }

    @Test func softnessCreatesPartialAlphaEdge() {
        let edgeAlpha = alpha(0.85, 0.85, 0.85, threshold: 0.9, softness: 0.1)
        #expect(edgeAlpha > 0.4 && edgeAlpha < 0.6, "soft edge should be partially transparent")
    }

    @Test func defaultThresholdIsNoOp() {
        #expect(alpha(1, 1, 1, threshold: 1, softness: 0.1) > 0.95, "threshold 1 should not key")
    }
}
