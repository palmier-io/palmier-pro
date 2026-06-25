import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("HighlightsShadowsKernel")
struct HighlightsShadowsKernelTests {

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

    private func apply(_ g: Double, h: Double, s: Double) -> Double {
        sample(HighlightsShadowsKernel.apply(solid(g, g, g), highlights: h, shadows: s)).0
    }

    @Test func neutralIsNoOp() {
        let out = sample(HighlightsShadowsKernel.apply(solid(0.6, 0.3, 0.2), highlights: 0, shadows: 0))
        #expect(max(abs(out.0 - 0.6), max(abs(out.1 - 0.3), abs(out.2 - 0.2))) < 1e-4)
    }

    @Test func highlightsAreSymmetric() {
        #expect(apply(0.85, h: 1, s: 0) > 0.9, "boost brightens highlights")
        #expect(apply(0.85, h: -1, s: 0) < 0.7, "negative recovers/darkens highlights")
    }

    @Test func shadowsAreSymmetric() {
        #expect(apply(0.15, h: 0, s: 1) > 0.3, "lift brightens shadows")
        #expect(apply(0.4, h: 0, s: -1) < 0.35, "negative deepens shadows")
    }

    @Test func highlightsBarelyTouchDeepShadows() {
        #expect(abs(apply(0.12, h: 1, s: 0) - 0.12) < 0.01, "highlights selective — leaves deep shadows")
    }

    @Test func huePreservedUnderLift() {
        // Additive luma delta keeps channel differences (hue) intact.
        let inRGB = (0.8, 0.3, 0.1)
        let out = sample(HighlightsShadowsKernel.apply(solid(inRGB.0, inRGB.1, inRGB.2), highlights: 0, shadows: 1))
        #expect(abs((out.0 - out.1) - (inRGB.0 - inRGB.1)) < 0.01, "r−g preserved")
        #expect(abs((out.1 - out.2) - (inRGB.1 - inRGB.2)) < 0.01, "g−b preserved")
    }
}
