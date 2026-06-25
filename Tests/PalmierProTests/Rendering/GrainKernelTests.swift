import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("GrainKernel")
struct GrainKernelTests {

    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let n = 64

    private func solid(_ v: Double) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v)).cropped(to: CGRect(x: 0, y: 0, width: n, height: n))
    }

    private func luma(_ image: CIImage) -> [Float] {
        var px = [Float](repeating: 0, count: n * n * 4)
        ctx.render(image, toBitmap: &px, rowBytes: n * 16,
                   bounds: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBAf, colorSpace: nil)
        return stride(from: 0, to: px.count, by: 4).map { px[$0] }
    }

    private func variance(_ vs: [Float]) -> Double {
        let m = vs.reduce(0, +) / Float(vs.count)
        return Double(vs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Float(vs.count))
    }

    @Test func neutralIsNoOp() {
        #expect(variance(luma(GrainKernel.apply(solid(0.5), amount: 0, size: 1.5, frame: 0))) < 1e-9)
    }

    @Test func addsNoise() {
        #expect(variance(luma(GrainKernel.apply(solid(0.5), amount: 1, size: 1.5, frame: 0))) > 1e-4)
    }

    @Test func strongestInMidtones() {
        let mid = variance(luma(GrainKernel.apply(solid(0.5), amount: 1, size: 1.5, frame: 0)))
        let dark = variance(luma(GrainKernel.apply(solid(0.04), amount: 1, size: 1.5, frame: 0)))
        #expect(mid > dark * 3, "grain should be much stronger in mids (\(mid) vs \(dark))")
    }

    @Test func animatesAcrossFrames() {
        let a = luma(GrainKernel.apply(solid(0.5), amount: 1, size: 1.5, frame: 0))
        let b = luma(GrainKernel.apply(solid(0.5), amount: 1, size: 1.5, frame: 20))
        let diff = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0 - $1.1)) } / Double(a.count)
        #expect(diff > 0.01, "different frames produce different grain")
    }
}
