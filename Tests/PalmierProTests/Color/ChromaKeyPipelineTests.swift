import Testing
import CoreImage
@testable import PalmierPro

@Suite("ChromaKeyPipeline matte")
struct ChromaKeyPipelineTests {

    static let greenHue = rgbToHSV(r: 0, g: 1, b: 0).h

    @Test func pureGreenIsKeyedOut() {
        let a = ChromaKeyPipeline.matteAlpha(r: 0, g: 1, b: 0, keyHue: Self.greenHue, tolerance: 40, softness: 20)
        #expect(a < 0.05)
    }

    @Test func skinToneIsKept() {
        let a = ChromaKeyPipeline.matteAlpha(r: 0.85, g: 0.6, b: 0.5, keyHue: Self.greenHue, tolerance: 40, softness: 20)
        #expect(a > 0.9)
    }

    @Test func redIsKept() {
        let a = ChromaKeyPipeline.matteAlpha(r: 1, g: 0, b: 0, keyHue: Self.greenHue, tolerance: 40, softness: 20)
        #expect(a > 0.95)
    }

    @Test func grayIsNeverKeyed() {
        let a = ChromaKeyPipeline.matteAlpha(r: 0.5, g: 0.5, b: 0.5, keyHue: Self.greenHue, tolerance: 100, softness: 0)
        #expect(a > 0.95)
    }

    @Test func spillPullsGreenCastTowardLuma() {
        let cast = ChromaKeyPipeline.spillCorrect(r: 0.4, g: 0.8, b: 0.4, keyHue: Self.greenHue, spill: 100)
        #expect(cast.g < 0.8) // green reduced
    }

    @Test func spillZeroIsNoOp() {
        let c = ChromaKeyPipeline.spillCorrect(r: 0.4, g: 0.8, b: 0.4, keyHue: Self.greenHue, spill: 0)
        #expect(c.g == 0.8)
    }

    @Test func renderedGreenBecomesTransparent() {
        let src = solidImage(r: 0, g: 1, b: 0)
        let out = ChromaKeyPipeline.apply(src, keyR: 0, keyG: 1, keyB: 0,
                                          tolerance: 40, softness: 20, spill: 50, edgeFeather: 0)
        let p = renderPixel(out)
        #expect(p.a < 0.1)
    }

    @Test func renderedSubjectStaysOpaque() {
        let src = solidImage(r: 1, g: 0, b: 0)
        let out = ChromaKeyPipeline.apply(src, keyR: 0, keyG: 1, keyB: 0,
                                          tolerance: 40, softness: 20, spill: 50, edgeFeather: 0)
        let p = renderPixel(out)
        #expect(p.a > 0.9)
    }
}
