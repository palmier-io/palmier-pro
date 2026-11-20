import Foundation
import Testing
@testable import CompositorPro

@Suite("add_captions default style")
@MainActor
struct AddCaptionsDefaultStyleTests {
    @Test("The curated default is subtitle, not the bare text style")
    func curatedDefaultIsSubtitle() {
        #expect(CaptionStyles.defaultStyle.id == "subtitle")
        #expect(CaptionStyles.defaultStyle.group == .onBox)
    }

    @Test("The resolved default differs from the legacy TextStyle.caption")
    func resolvedDefaultIsNotLegacy() {
        let resolved = CaptionStyles.defaultStyle.resolved(canvasHeight: 1080)
        // The legacy fallback only set a font size; the curated default carries a real face,
        // weight, and scrim so captions are readable over footage.
        #expect(resolved.style.fontName == "Inter")
        #expect(resolved.style.isBold)
        #expect(resolved.style.background.enabled)
        #expect(resolved.style.background.color.a > 0)
        #expect(resolved.center.y > 0)
    }

    @Test("The gallery is the default-expanded section in the Captions panel")
    func galleryIsReachableByDefault() {
        // The Style section must be open so the gallery is visible without a disclosure tap.
        // Verified structurally: CaptionTab declares styleExpanded default true.
        let source = try? String(contentsOfFile: "Sources/CompositorPro/MediaPanel/CaptionsTab/CaptionTab.swift",
                                 encoding: .utf8)
        #expect(source?.contains("@State private var styleExpanded = true") == true)
    }
}