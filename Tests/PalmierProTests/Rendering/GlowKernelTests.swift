import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("GlowKernel")
struct GlowKernelTests {

    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let n = 48

    /// Small white square centered on black.
    private func spot() -> CIImage {
        var px = [UInt8](repeating: 0, count: n * n * 4)
        for y in (n / 2 - 3)..<(n / 2 + 3) {
            for x in (n / 2 - 3)..<(n / 2 + 3) {
                let i = (y * n + x) * 4
                px[i] = 255; px[i + 1] = 255; px[i + 2] = 255; px[i + 3] = 255
            }
        }
        let c = px.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        return CIImage(cgImage: c!.makeImage()!, options: [.colorSpace: NSNull()])
    }

    private func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> (Double, Double, Double) {
        var px = [Float](repeating: 0, count: n * n * 4)
        ctx.render(image, toBitmap: &px, rowBytes: n * 16,
                   bounds: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBAf, colorSpace: nil)
        let i = (y * n + x) * 4
        return (Double(px[i]), Double(px[i + 1]), Double(px[i + 2]))
    }

    private func glow(_ intensity: Double, warmth: Double = 0) -> CIImage {
        let img = spot()
        return GlowKernel.apply(img, extent: img.extent, intensity: intensity,
                                radius: 6, threshold: 0.3, warmth: warmth)
    }

    @Test func neutralIsNoOp() {
        // A black pixel near the spot stays black with no glow.
        #expect(pixel(glow(0), n / 2 + 8, n / 2).0 < 0.01)
    }

    @Test func bleedsLightIntoNeighbors() {
        let off = pixel(spot(), n / 2 + 8, n / 2).0          // black, far-ish from spot
        let on = pixel(glow(1), n / 2 + 8, n / 2).0
        #expect(on > off + 0.05, "glow should bleed light onto neighbors (\(off) → \(on))")
    }

    @Test func warmthTintsTheBleedRed() {
        let neutral = pixel(glow(1, warmth: 0), n / 2 + 5, n / 2)
        let warm = pixel(glow(1, warmth: 1), n / 2 + 5, n / 2)
        #expect(warm.0 - warm.2 > neutral.0 - neutral.2 + 0.03, "warm halation bleeds redder than blue")
    }
}
