import Foundation
import Testing
@testable import PalmierPro

@Suite("TextFillMode")
struct TextFillModeTests {
    @Test func setFootageClearsIncompatibleDecorations() {
        var clip = Fixtures.clip(id: "txt", mediaRef: "", mediaType: .text, start: 0, duration: 60)
        var style = TextStyle()
        style.shadow.enabled = true
        style.background.enabled = true
        style.border.enabled = true
        style.border.width = 8
        clip.textStyle = style
        clip.textAnimation = TextAnimation(
            preset: .highlightBlock,
            highlight: .init(r: 1, g: 0, b: 0, a: 1)
        )
        clip.effects = [Effect.make("color.exposure", ["ev": 1])]

        clip.setTextFillMode(.footage)

        #expect(clip.textFillMode == .footage)
        #expect(clip.textStyle?.shadow.enabled == false)
        #expect(clip.textStyle?.background.enabled == false)
        #expect(clip.textStyle?.border.enabled == false)
        #expect(clip.textAnimation == nil)
        #expect(clip.effects == nil)
    }

    @Test func stripDropsHighlightPresetsWhileKeepingReveal() {
        var clip = Fixtures.clip(id: "txt", mediaRef: "", mediaType: .text, start: 0, duration: 60)
        clip.textFillMode = .footage
        clip.textAnimation = TextAnimation(
            preset: .wordReveal,
            highlight: .init(r: 1, g: 0.85, b: 0, a: 1)
        )

        clip.stripFootageIncompatibleTextStyle()

        #expect(clip.textAnimation?.preset == .wordReveal)
        #expect(clip.textAnimation?.highlight == nil)
    }

    @Test func captionGroupsRejectFootageFill() {
        var clip = Fixtures.clip(id: "caption", mediaRef: "", mediaType: .text, start: 0, duration: 60)
        clip.captionGroupId = "captions"

        clip.setTextFillMode(.footage)

        #expect(clip.textFillMode == nil)
    }

    @Test func decodeFootageStripsLegacyDecorations() throws {
        var style = TextStyle()
        style.border.enabled = true
        let clip = Clip(
            id: "txt",
            mediaRef: "",
            mediaType: .text,
            sourceClipType: .text,
            startFrame: 0,
            durationFrames: 60,
            textStyle: style,
            textAnimation: TextAnimation(preset: .highlightPop),
            textFillMode: .footage,
            effects: [Effect.make("blur.gaussian", ["radius": 10])]
        )
        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(Clip.self, from: data)

        #expect(decoded.textFillMode == .footage)
        #expect(decoded.textStyle?.border.enabled == false)
        #expect(decoded.textAnimation == nil)
        #expect(decoded.effects == nil)
    }

    @Test func decodeCaptionNormalizesLegacyFootageFill() throws {
        let clip = Clip(
            id: "caption",
            mediaRef: "",
            mediaType: .text,
            sourceClipType: .text,
            startFrame: 0,
            durationFrames: 60,
            captionGroupId: "captions",
            textFillMode: .footage
        )

        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(Clip.self, from: data)

        #expect(decoded.textFillMode == nil)
    }
}
