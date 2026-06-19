import Testing
import CoreImage
@testable import PalmierPro

@Suite("ColorGradePipeline")
struct ColorGradePipelineTests {

    @Test func neutralBasicIsIdentity() {
        let src = solidImage(r: 0.3, g: 0.5, b: 0.7)
        let out = ColorGradePipeline.basic(src, temperature: 0, tint: 0, exposure: 0, contrast: 0, saturation: 0)
        let p = renderPixel(out)
        #expect(abs(p.r - 0.3) < 0.02)
        #expect(abs(p.g - 0.5) < 0.02)
        #expect(abs(p.b - 0.7) < 0.02)
    }

    @Test func positiveExposureBrightens() {
        let src = solidImage(r: 0.3, g: 0.3, b: 0.3)
        let out = ColorGradePipeline.basic(src, temperature: 0, tint: 0, exposure: 50, contrast: 0, saturation: 0)
        let p = renderPixel(out)
        #expect(p.r > 0.35)
    }

    @Test func lutIntensityZeroReturnsSource() throws {
        let lut = try CubeLUT.parse(CubeLUTTests.identity2)
        let src = solidImage(r: 0.4, g: 0.2, b: 0.6)
        let out = ColorGradePipeline.lut(src, cube: lut, intensity: 0)
        let p = renderPixel(out)
        #expect(abs(p.r - 0.4) < 0.02)
        #expect(abs(p.g - 0.2) < 0.02)
        #expect(abs(p.b - 0.6) < 0.02)
    }

    @Test func identityLUTLeavesColorUnchanged() throws {
        let lut = try CubeLUT.parse(CubeLUTTests.identity2)
        let src = solidImage(r: 0.4, g: 0.2, b: 0.6)
        let out = ColorGradePipeline.lut(src, cube: lut, intensity: 1)
        let p = renderPixel(out)
        #expect(abs(p.r - 0.4) < 0.03)
        #expect(abs(p.g - 0.2) < 0.03)
        #expect(abs(p.b - 0.6) < 0.03)
    }
}
