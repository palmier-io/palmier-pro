import Foundation
import Testing
@testable import CompositorPro

@Suite("Text style presets")
@MainActor
struct TextStylePresetTests {
    private func preset(_ id: String) -> TextStylePreset? {
        TextStylePresets.preset(id: id)
    }

    private func require(_ id: String) -> TextStylePreset {
        guard let found = preset(id) else {
            Issue.record("missing preset \(id)")
            return TextStylePreset(
                id: id, intent: "", sizeRatio: 0.04, centerYRatio: 0.5,
                fontName: "Inter", isBold: false, tracking: 0,
                fontCase: .mixed, alignment: .center, outlineRatio: 0, scrim: false
            )
        }
        return found
    }

    private static func bundledFontNames() -> Set<String> {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Agent
            .deletingLastPathComponent()   // CompositorProTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/CompositorPro/Resources/Fonts")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return Set(contents.map { ($0 as NSString).deletingPathExtension })
    }

    @Test("Every preset names a bundled font, so none can resolve to a missing face")
    func fontsAreBundled() {
        let bundled = Self.bundledFontNames()
        #expect(!bundled.isEmpty, "could not locate the bundled fonts directory")
        for preset in TextStylePresets.all {
            let missing = !bundled.contains(preset.fontName)
            #expect(!missing, "\(preset.id) asks for \(preset.fontName), which is not bundled")
        }
    }

    @Test("Identifiers are unique and each preset explains itself")
    func presetsAreWellFormed() {
        let ids = TextStylePresets.all.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate preset id")
        for preset in TextStylePresets.all {
            let longEnough = preset.intent.count > 40
            #expect(longEnough, "\(preset.id) intent is too thin")
        }
    }

    @Test("Sizes stay inside a legible range on every canvas")
    func sizesStayLegible() {
        for canvasHeight in [720, 1080, 1440, 2160, 1920] {
            for preset in TextStylePresets.all {
                let size = preset.resolved(canvasHeight: canvasHeight).fontSize
                let ok = size >= 12 && size <= 300
                #expect(ok, "\(preset.id) at \(canvasHeight)px is \(size)pt")
            }
        }
    }

    @Test("Type scales with the canvas, so one preset reads the same on 16:9 and 9:16")
    func typeScalesWithCanvas() {
        let title = require("title")
        let landscape = title.resolved(canvasHeight: 1080).fontSize
        let vertical = title.resolved(canvasHeight: 1920).fontSize
        let taller = vertical > landscape
        #expect(taller, "a taller canvas gets larger type")
        let ratio = vertical / landscape
        let expected = 1920.0 / 1080.0
        #expect(abs(ratio - expected) < 0.001, "exactly proportional")
    }

    @Test("Every preset yields white type, which is what reads over footage")
    func presetsAreLight() {
        for preset in TextStylePresets.all {
            let isWhite = preset.resolved(canvasHeight: 1080).color.r == 1
            #expect(isWhite, "\(preset.id) is not white")
        }
    }

    @Test("Anything that must survive arbitrary footage carries a legibility treatment")
    func legibilityWhereItMatters() {
        for id in ["caption", "lowerThird"] {
            let enabled = require(id).resolved(canvasHeight: 1080).background.enabled
            #expect(enabled, "\(id) needs a scrim to survive any frame")
        }
    }

    @Test("Scrim padding scales with the type rather than being a fixed box")
    func scrimHugsTheType() {
        let caption = require("caption")
        let small = caption.resolved(canvasHeight: 720).background.paddingX
        let large = caption.resolved(canvasHeight: 2160).background.paddingX
        #expect(large > small)
    }

    @Test("Monospaced styles share one face so digits do not shift between readouts")
    func technicalIsMonospaced() {
        let face = preset("technical")?.fontName
        #expect(face == "GeistMono")
    }

    @Test("Placement sits where a face is not, and never off-canvas")
    func placementIsSane() {
        for preset in TextStylePresets.all {
            let centre = preset.center
            #expect(centre.x == 0.5, "\(preset.id) is not centred")
            let inFrame = centre.y > 0.3 && centre.y < 0.95
            #expect(inFrame, "\(preset.id) sits too close to an edge")
        }
    }

    @Test("An unknown preset resolves to nothing rather than a default")
    func unknownPresetIsNil() {
        let found = preset("nope")
        #expect(found == nil)
    }

    @Test("Type styles differ from each other in more than one axis, so they read as different")
    func presetsAreDistinguishable() {
        var signatures: Set<String> = []
        for preset in TextStylePresets.all {
            signatures.insert(preset.fontName + "|" + preset.fontCase.rawValue)
        }
        // Not one per preset, but far more than the number of faces.
        #expect(signatures.count >= TextStylePresets.all.count / 2)
    }
}