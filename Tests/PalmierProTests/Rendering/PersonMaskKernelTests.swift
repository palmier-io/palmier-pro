import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("PersonMaskKernel")
struct PersonMaskKernelTests {

    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func solid(_ v: Double) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    private func alpha(_ image: CIImage) -> Double {
        var px = [Float](repeating: 0, count: 4)
        ctx.render(image, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBAf, colorSpace: nil)
        return Double(px[3])
    }

    private func effect(invert: Double = 0, feather: Double = 0) -> Effect {
        Effect(type: "key.personMask", params: [
            "invert": EffectParam(value: invert),
            "feather": EffectParam(value: feather),
        ])
    }

    @Test func fullCoverageStaysOpaqueWhenNotInverted() {
        let source = solid(1)
        let matte = solid(1) // full coverage
        let out = PersonMaskKernel.apply(source, matte: matte, effect: effect(), atOffset: 0)
        #expect(alpha(out) > 0.95, "selected person should stay opaque")
    }

    @Test func zeroCoverageBecomesTransparentWhenNotInverted() {
        let source = solid(1)
        let matte = solid(0) // no coverage
        let out = PersonMaskKernel.apply(source, matte: matte, effect: effect(), atOffset: 0)
        #expect(alpha(out) < 0.05, "background should be masked out")
    }

    @Test func invertFlipsCoverage() {
        let source = solid(1)
        let matte = solid(1) // full coverage — the person
        let out = PersonMaskKernel.apply(source, matte: matte, effect: effect(invert: 1), atOffset: 0)
        #expect(alpha(out) < 0.05, "inverted: the person themself should be cut out")

        let matteBG = solid(0) // background
        let outBG = PersonMaskKernel.apply(source, matte: matteBG, effect: effect(invert: 1), atOffset: 0)
        #expect(alpha(outBG) > 0.95, "inverted: background should stay opaque")
    }

    @Test func noMatteFailsOpen() {
        let source = solid(1)
        let out = PersonMaskKernel.apply(source, matte: nil, effect: effect(), atOffset: 0)
        #expect(alpha(out) > 0.95, "missing matte (e.g. cleared cache) should leave the image untouched")
    }

    @Test func featherSoftensPartialCoverageWithoutCrashing() {
        let source = solid(1)
        let matte = solid(0.5)
        let out = PersonMaskKernel.apply(source, matte: matte, effect: effect(feather: 1), atOffset: 0)
        let a = alpha(out)
        #expect(a > 0 && a < 1, "feathered half-coverage should be partially transparent")
    }
}
