import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("VignetteKernel")
struct VignetteKernelTests {

    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let n = 100

    private func solid(_ v: Double) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v)).cropped(to: CGRect(x: 0, y: 0, width: n, height: n))
    }

    /// Renders the vignetted image and returns the green value at center vs. a corner.
    private func centerAndCorner(_ image: CIImage) -> (center: Double, corner: Double) {
        var px = [Float](repeating: 0, count: n * n * 4)
        ctx.render(image, toBitmap: &px, rowBytes: n * 16,
                   bounds: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBAf, colorSpace: nil)
        func at(_ x: Int, _ y: Int) -> Double { Double(px[(y * n + x) * 4]) }
        return (at(n / 2, n / 2), at(3, 3))
    }

    private func vignette(_ image: CIImage, amount: Double, midpoint: Double = 0.3,
                          roundness: Double = 0, feather: Double = 0.3) -> CIImage {
        VignetteKernel.apply(image, extent: image.extent, amount: amount,
                             midpoint: midpoint, roundness: roundness, feather: feather)
    }

    @Test func neutralIsNoOp() {
        let (c, corner) = centerAndCorner(vignette(solid(0.7), amount: 0))
        #expect(abs(c - 0.7) < 1e-3 && abs(corner - 0.7) < 1e-3)
    }

    @Test func darkensEdgesNotCenter() {
        let (c, corner) = centerAndCorner(vignette(solid(1.0), amount: -1))
        #expect(c > 0.9, "center stays bright, got \(c)")
        #expect(corner < 0.1, "corner darkens, got \(corner)")
    }

    @Test func positiveAmountLightensEdges() {
        let (c, corner) = centerAndCorner(vignette(solid(0.5), amount: 1))
        #expect(abs(c - 0.5) < 0.02, "center unchanged, got \(c)")
        #expect(corner > 0.7, "corner brightens, got \(corner)")
    }

    @Test func midpointMovesTheReach() {
        // A larger midpoint pulls the vignette outward, so the corner darkens less.
        let near = centerAndCorner(vignette(solid(1.0), amount: -1, midpoint: 0.2)).corner
        let far = centerAndCorner(vignette(solid(1.0), amount: -1, midpoint: 0.8)).corner
        #expect(far > near, "higher midpoint = less corner darkening (\(far) vs \(near))")
    }
}
