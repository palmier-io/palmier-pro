import Foundation
import Testing
@testable import CompositorPro

@Suite("Clip composite layer and editorial metadata")
struct ClipLayerTests {

    // MARK: - Defaults

    @Test("A clip defaults to the primary composite layer")
    func defaultLayerIsPrimary() {
        let clip = Fixtures.clip(start: 0, duration: 100)
        #expect(clip.compositeLayer == .primary)
        #expect(clip.editorialReason == nil)
        #expect(clip.backgroundColor == nil)
    }

    @Test("All layer cases are representable")
    func layerCases() {
        #expect(CompositeLayer.allCases == [.primary, .overlay, .background])
        #expect(CompositeLayer.primary.rawValue == "primary")
        #expect(CompositeLayer.overlay.rawValue == "overlay")
        #expect(CompositeLayer.background.rawValue == "background")
    }

    // MARK: - Assignment

    @Test("Overlay layer and editorial reason stick on a clip")
    func overlayLayerAndReason() {
        let color = TextStyle.RGBA(r: 0, g: 0, b: 0, a: 1)
        let clip = Fixtures.clip(
            start: 0, duration: 100,
            compositeLayer: .overlay,
            editorialReason: "hero moment",
            backgroundColor: color
        )
        #expect(clip.compositeLayer == .overlay)
        #expect(clip.editorialReason == "hero moment")
        #expect(clip.backgroundColor == color)
    }

    @Test("Background layer with nil reason and color is still valid")
    func backgroundLayerMinimal() {
        let clip = Fixtures.clip(start: 0, duration: 100, compositeLayer: .background)
        #expect(clip.compositeLayer == .background)
        #expect(clip.editorialReason == nil)
        #expect(clip.backgroundColor == nil)
    }

    // MARK: - Codable round trip

    @Test("New fields survive JSON encode/decode")
    func codableRoundTrip() throws {
        let original = Fixtures.clip(
            start: 10, duration: 50,
            compositeLayer: .overlay,
            editorialReason: "cutaway",
            backgroundColor: TextStyle.RGBA(r: 1, g: 0.5, b: 0, a: 0.8)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Clip.self, from: data)
        #expect(decoded.compositeLayer == .overlay)
        #expect(decoded.editorialReason == "cutaway")
        #expect(decoded.backgroundColor == TextStyle.RGBA(r: 1, g: 0.5, b: 0, a: 0.8))
        #expect(decoded.endFrame == 60)
    }

    @Test("Missing fields decode to defaults (backwards compatible)")
    func missingFieldsDecodeToDefaults() throws {
        let json = """
        {"id":"x","mediaRef":"m","startFrame":0,"durationFrames":10}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Clip.self, from: json)
        #expect(decoded.compositeLayer == .primary)
        #expect(decoded.editorialReason == nil)
        #expect(decoded.backgroundColor == nil)
    }
}
