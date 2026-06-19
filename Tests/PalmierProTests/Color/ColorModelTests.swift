import Testing
import Foundation
@testable import PalmierPro

@Suite("Colour model")
struct ColorModelTests {

    @Test func colorGradeDefaultIsNoEffect() {
        #expect(ColorGrade().hasEffect == false)
    }

    @Test func colorGradeBasicEffectGate() {
        var g = ColorGrade()
        g.contrast = 10
        #expect(g.hasBasicEffect)
        g.basicEnabled = false
        #expect(g.hasBasicEffect == false)
        #expect(g.hasEffect == false)
    }

    @Test func colorGradeLUTEffectGate() {
        var g = ColorGrade()
        g.lutRef = "look.cube"
        #expect(g.hasLUTEffect)
        g.lutIntensity = 0
        #expect(g.hasLUTEffect == false)
    }

    @Test func chromaKeyDefaultsToInactiveGreen() {
        let k = ChromaKey()
        #expect(k.isActive == false)
        #expect(k.keyColor == TextStyle.RGBA(r: 0, g: 1, b: 0, a: 1))
    }

    @Test func clipRoundTripsColorFields() throws {
        var clip = Clip(mediaRef: "m", startFrame: 0, durationFrames: 30)
        clip.chromaKey = ChromaKey(enabled: true, tolerance: 55)
        clip.colorGrade = ColorGrade(contrast: 20, lutRef: "look.cube")

        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(Clip.self, from: data)

        #expect(decoded.chromaKey == clip.chromaKey)
        #expect(decoded.colorGrade == clip.colorGrade)
    }

    @Test func oldClipJSONDecodesWithNilColorFields() throws {
        let json = #"{"mediaRef":"m","startFrame":0,"durationFrames":30}"#
        let clip = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        #expect(clip.chromaKey == nil)
        #expect(clip.colorGrade == nil)
        #expect(clip.opacity == 1.0)
    }

    @Test func blendModeRoundTripsAndMapsToFilter() throws {
        var clip = Clip(mediaRef: "m", startFrame: 0, durationFrames: 30)
        clip.blendMode = .multiply
        let decoded = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
        #expect(decoded.blendMode == .multiply)
        #expect(BlendMode.normal.ciFilterName == nil)
        #expect(BlendMode.screen.ciFilterName == "CIScreenBlendMode")
    }

    @Test func adjustmentClipTypeIsNotVisualSource() {
        #expect(ClipType.adjustment.isAdjustment)
        #expect(ClipType.adjustment.isVisual == false)
    }
}
