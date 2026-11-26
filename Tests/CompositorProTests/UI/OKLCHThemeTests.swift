import AppKit
import Testing
@testable import CompositorPro

@Suite("OKLCH theme")
@MainActor
struct OKLCHThemeTests {
    @Test func neutralEndpointsConvertExactly() {
        let black = OKLCHConverter.convert(.init(lightness: 0, chroma: 0, hue: 0))
        #expect(black.red == 0 && black.green == 0 && black.blue == 0)

        let white = OKLCHConverter.convert(.init(lightness: 1, chroma: 0, hue: 0))
        #expect(abs(white.red - 1) < 0.0001)
        #expect(abs(white.green - 1) < 0.0001)
        #expect(abs(white.blue - 1) < 0.0001)
    }

    @Test func channelsStayInRangeAndAlphaSurvives() {
        let color = OKLCHConverter.convert(.init(lightness: 0.7, chroma: 0.4, hue: 30, alpha: 0.35))
        for channel in [color.red, color.green, color.blue] {
            #expect(channel >= 0 && channel <= 1)
        }
        #expect(abs(color.alpha - 0.35) < 0.0001)
    }

    @Test func nonFiniteInputFallsBackToBlack() {
        let bad = OKLCHConverter.convert(.init(lightness: .nan, chroma: 0.1, hue: 0))
        #expect(bad.red == 0 && bad.green == 0 && bad.blue == 0)
    }

    @Test func appearancesResolveToDistinctCachedInstances() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))

        #expect(OKLCHTheme.resolved(for: light) == OKLCHTheme.light)
        #expect(OKLCHTheme.resolved(for: dark) == OKLCHTheme.dark)
        #expect(OKLCHTheme.resolved(for: light) != OKLCHTheme.dark)
        // Distinct semantic values, so a theme swap is observable.
        #expect(OKLCHTheme.light.background != OKLCHTheme.dark.background)
    }

    @Test func everyRoleResolvesToAnOpaqueColor() throws {
        let appearance = try #require(NSAppearance(named: .darkAqua))
        let theme = OKLCHTheme.resolved(for: appearance)
        for role in [OKLCHTheme.Role.background, .card, .primary, .accent, .destructive, .border, .sidebarBackground, .sidebarForeground] {
            let color = theme.color(for: role, appearance: appearance)
            #expect(color.alphaComponent > 0)
        }
    }
}
