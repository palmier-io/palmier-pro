import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("ClarityKernel")
struct ClarityKernelTests {

    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let n = 64

    /// Left half dark, right half bright — a single vertical edge down the middle.
    private func edgeImage() -> CIImage {
        var px = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let v: UInt8 = x < n / 2 ? 77 : 178  // 0.3 / 0.7
                let i = (y * n + x) * 4
                px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255
            }
        }
        let ctx2 = px.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        return CIImage(cgImage: ctx2!.makeImage()!, options: [.colorSpace: NSNull()])
    }

    private func luma(_ image: CIImage) -> [Float] {
        var px = [Float](repeating: 0, count: n * n * 4)
        ctx.render(image, toBitmap: &px, rowBytes: n * 16,
                   bounds: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBAf, colorSpace: nil)
        return stride(from: 0, to: px.count, by: 4).map { px[$0] }
    }

    @Test func neutralIsNoOp() {
        let img = edgeImage()
        let base = luma(img), out = luma(ClarityKernel.apply(img, extent: img.extent, clarity: 0, dehaze: 0))
        #expect(zip(base, out).allSatisfy { abs($0 - $1) < 1e-4 })
    }

    @Test func dehazeReSaturatesWashedRegion() {
        // A bright, low-saturation (hazy) patch should come back with more contrast/saturation.
        let img = CIImage(color: CIColor(red: 0.70, green: 0.73, blue: 0.78))
            .cropped(to: CGRect(x: 0, y: 0, width: n, height: n))
        func sat(_ image: CIImage) -> Double {
            var px = [Float](repeating: 0, count: 4)
            ctx.render(image, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
            let mx = max(px[0], max(px[1], px[2])), mn = min(px[0], min(px[1], px[2]))
            return mx <= 1e-5 ? 0 : Double((mx - mn) / mx)
        }
        let before = sat(img)
        let after = sat(ClarityKernel.apply(img, extent: img.extent, clarity: 0, dehaze: 1))
        #expect(after > before + 0.02, "dehaze should re-saturate the haze (\(before) → \(after))")
    }

    @Test func clarityBoostsEdgeNotFlatRegions() {
        let img = edgeImage()
        let base = luma(img), out = luma(ClarityKernel.apply(img, extent: img.extent, clarity: 1, dehaze: 0))
        func at(_ x: Int, _ y: Int, _ a: [Float]) -> Float { a[y * n + x] }
        // Deep in the left flat region: no local contrast → unchanged.
        #expect(abs(at(4, 32, base) - at(4, 32, out)) < 0.01, "flat region unchanged")
        // Immediately left of the edge: clarity overshoots darker.
        let edgeDelta = at(31, 32, out) - at(31, 32, base)
        #expect(edgeDelta < -0.02, "dark side of edge gets darker, delta \(edgeDelta)")
    }
}
