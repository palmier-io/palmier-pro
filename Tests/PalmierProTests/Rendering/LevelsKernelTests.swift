import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("LevelsKernel")
struct LevelsKernelTests {

    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func solid(_ v: Double) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    private func gray(_ v: Double, blacks: Double, whites: Double) -> Double {
        var px = [Float](repeating: 0, count: 4)
        ctx.render(LevelsKernel.apply(solid(v), blacks: blacks, whites: whites),
                   toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBAf, colorSpace: nil)
        return Double(px[0])
    }

    @Test func neutralIsNoOp() {
        #expect(abs(gray(0.42, blacks: 0, whites: 0) - 0.42) < 1e-4)
    }

    @Test func blacksCrushAndLift() {
        #expect(gray(0.2, blacks: -1, whites: 0) < 0.2, "crush deepens darks")
        #expect(gray(0.05, blacks: 1, whites: 0) > 0.05, "lift raises the floor")
    }

    @Test func whitesBrightenAndRecover() {
        #expect(gray(0.7, blacks: 0, whites: 1) > 0.9, "brighten pushes highs to white")
        #expect(gray(1.0, blacks: 0, whites: -1) < 0.85, "recover pulls the white point down")
    }

    @Test func remapIsMonotonic() {
        // A strong stretch keeps tonal order — no inversions.
        var prev = -1.0
        for i in 0...20 {
            let out = gray(Double(i) / 20, blacks: -0.5, whites: 0.6)
            #expect(out >= prev - 1e-4, "monotonic at \(i): \(out) < \(prev)")
            prev = out
        }
    }
}
