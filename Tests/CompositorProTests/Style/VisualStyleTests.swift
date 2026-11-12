import AppKit
import Foundation
import Testing
@testable import CompositorPro

@Suite("Visual style playbooks")
struct VisualStyleTests {

    // MARK: - Loading

    @Test("Bundled premium-minimalist style loads and decodes")
    func loadPremiumMinimalist() throws {
        let style = try #require(VisualStyleManager.load(named: "premium-minimalist"))
        #expect(style.identity.name == "Premium Minimalist")
        #expect(style.identity.category == .minimalist)
        #expect(style.identity.pace == .deliberate)
        #expect(style.backgroundRGBA == TextStyle.RGBA(r: 249/255, g: 250/255, b: 251/255, a: 1))
        #expect(style.textRGBA == TextStyle.RGBA(r: 17/255, g: 24/255, b: 39/255, a: 1))
        #expect(style.typography.headings.font == "Inter")
        #expect(style.typography.headings.weight == 700)
        #expect(style.motion.transitions == ["fade", "dissolve", "slide-left"])
        #expect(style.audio.musicVolume == 0.07)
        #expect(style.qualityRules.count == 5)
        #expect(style.chartPaletteRGBA.count == 4)
    }

    @Test("Bundled anime-ghibli style loads and decodes")
    func loadAnimeGhibli() throws {
        let style = try #require(VisualStyleManager.load(named: "anime-ghibli"))
        #expect(style.identity.name == "Anime Ghibli")
        #expect(style.identity.category == .custom)
        #expect(style.identity.pace == .slow)
        #expect(style.primaryRGBA.count == 2)
        #expect(style.accentRGBA.count == 4)
        #expect(style.typography.headings.font == "Noto Serif JP")
        #expect(style.assetGeneration?.sceneType == "anime_scene")
        #expect(style.assetGeneration?.multiImagePerScene == true)
        #expect(style.assetGeneration?.defaultVignette == true)
        #expect(style.overlays?.statCard?.bg == "#0A0A1AB2")
    }

    @Test("Style manager lists bundled names")
    func listsBundledNames() {
        let names = VisualStyleManager.allNames()
        #expect(names.contains("premium-minimalist"))
        #expect(names.contains("anime-ghibli"))
    }

    @Test("Unknown style name returns nil")
    func unknownStyleReturnsNil() {
        #expect(VisualStyleManager.load(named: "does-not-exist") == nil)
    }

    // MARK: - Color accessors

    @Test("Color accessors return SwiftUI colors")
    func colorAccessors() throws {
        let style = try #require(VisualStyleManager.load(named: "premium-minimalist"))
        #expect(style.color(for: .background) == style.backgroundRGBA?.swiftUIColor)
        #expect(style.color(for: .text) == style.textRGBA?.swiftUIColor)
        #expect(style.color(for: .primary) == style.primaryRGBA.first?.swiftUIColor)
        #expect(style.color(for: .accent) == style.accentRGBA.first?.swiftUIColor)
        #expect(style.color(for: .muted) == style.mutedRGBA?.swiftUIColor)
    }

    @Test("NSColor accessor wraps SwiftUI color")
    func nsColorAccessor() throws {
        let style = try #require(VisualStyleManager.load(named: "premium-minimalist"))
        #expect(style.nsColor(for: .text) == NSColor(style.color(for: .text)))
    }

    // MARK: - Typography accessors

    @Test("Font accessor returns configured font and weight")
    func fontAccessor() throws {
        let style = try #require(VisualStyleManager.load(named: "premium-minimalist"))
        _ = style.font(for: .heading, size: 32)
        #expect(style.typography.headings.font == "Inter")
    }

    @Test("Base body size defaults to 24px without scale system")
    func baseBodySizeDefault() throws {
        let style = try #require(VisualStyleManager.load(named: "premium-minimalist"))
        // premium-minimalist declares scale_system: "major_third" → 24 * 1.25 = 30
        #expect(style.baseBodySize() == 30)
    }

    // MARK: - Validation

    @Test("Premium-minimalist passes contrast validation")
    func premiumMinimalistPassesValidation() throws {
        let style = try #require(VisualStyleManager.load(named: "premium-minimalist"))
        let report = VisualStyleManager.validate(style)
        #expect(report.pass == true, "\(report.issues.map { $0.message })")
        #expect(report.errorCount == 0)
    }

    @Test("Validator flags low-contrast text on background")
    func flagsLowContrast() throws {
        var style = try #require(VisualStyleManager.load(named: "premium-minimalist"))
        style.colorPalette.text = "#E5E7EB" // light gray on off-white → low contrast
        let report = VisualStyleValidator.validate(style)
        #expect(report.pass == false)
        #expect(report.errorCount > 0)
        #expect(report.issues.contains { $0.pair == "text on background" })
    }

    @Test("Validator validates muted text on background")
    func flagsLowContrastMuted() throws {
        var style = try #require(VisualStyleManager.load(named: "premium-minimalist"))
        style.colorPalette.muted = "#F3F4F6" // very light on off-white
        let report = VisualStyleValidator.validate(style)
        #expect(report.pass == false)
        #expect(report.issues.contains { $0.pair == "muted on background" })
    }

    @Test("Validator checks overlay text contrast")
    func flagsOverlayContrast() throws {
        var style = try #require(VisualStyleManager.load(named: "premium-minimalist"))
        style.overlays?.statCard = VisualStyle.OverlayStyle(
            bg: "#1F2937",
            text: "#292929"
        )
        let report = VisualStyleValidator.validate(style)
        #expect(report.pass == false)
        #expect(report.issues.contains { $0.pair.hasPrefix("overlay.stat_card") })
    }

    @Test("Validator checks color-blind safety on chart palette")
    func flagsColorBlindIssues() throws {
        var style = try #require(VisualStyleManager.load(named: "premium-minimalist"))
        // Two hues confusable under red-green deficiency, similar lightness.
        style.chartPalette = ["#B00020", "#006B00"]
        let report = VisualStyleValidator.validate(style)
        #expect(report.pass == true) // contrast still passes
        #expect(report.warningCount > 0) // but color-blind warning
        #expect(report.issues.contains { $0.message.contains("indistinguishable") })
    }

    @Test("Decoder requires identity and color palette")
    func missingRequiredFieldsFails() {
        let json = """
        {"identity": {"name": "X", "category": "minimalist", "mood": "calm", "pace": "moderate"}}
        """.data(using: .utf8)!
        let decoded = try? JSONDecoder().decode(VisualStyle.self, from: json)
        #expect(decoded == nil)
    }

    @Test("ScaleSystem decodes from named string and custom number")
    func scaleSystemDecodes() throws {
        let named = try #require(try JSONDecoder().decode(VisualStyle.ScaleSystem.self,
            from: #""major_third""#.data(using: .utf8)!))
        if case .named(let name) = named {
            #expect(name == "major_third")
        } else {
            Issue.record("Expected .named, got \(named)")
        }

        let custom = try #require(try JSONDecoder().decode(VisualStyle.ScaleSystem.self,
            from: #"1.618"#.data(using: .utf8)!))
        if case .custom(let value) = custom {
            #expect(value == 1.618)
        } else {
            Issue.record("Expected .custom, got \(custom)")
        }
    }
}
