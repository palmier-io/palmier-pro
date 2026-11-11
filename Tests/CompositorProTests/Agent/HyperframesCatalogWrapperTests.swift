import Foundation
import Testing
@testable import CompositorPro

@Suite("HyperFrames Catalog Wrapper")
struct HyperframesCatalogWrapperTests {

    @Test func loadAndExportCatalogRoundtripsCorrectly() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let block1 = HyperframesBlock(
            id: "title-01",
            name: "Kinetic Intro",
            category: "titles",
            tags: ["bold", "kinetic"],
            description: "High impact title",
            path: "blocks/title-01/block.json",
            assets: ["assets/font.woff2", "assets/graphic.svg"],
            defaultDurationFrames: 60
        )
        let block2 = HyperframesBlock(
            id: "lower-third-01",
            name: "Modern Lower Third",
            category: "captions",
            tags: ["clean"],
            description: "Sleek lower third",
            path: "blocks/lower-third-01/block.json",
            assets: ["assets/badge.png"],
            defaultDurationFrames: 90
        )

        try await HyperframesCatalogWrapper.exportCatalog([block1, block2], to: tempDir)

        let loaded = try await HyperframesCatalogWrapper.loadCatalog(from: tempDir)
        #expect(loaded.count == 2)
        #expect(loaded[0].id == "title-01")
        #expect(loaded[0].defaultDurationFrames == 60)
        #expect(loaded[1].name == "Modern Lower Third")
    }

    @Test func inspectBlockSpecAndGenerateHTMLWithDesignSpec() async throws {
        let spec = HyperframesBlockSpec(
            id: "hero-title",
            name: "Hero Title",
            category: "titles",
            parameters: [
                HyperframesParameter(id: "title", name: "Title Text", type: .text, defaultValue: "Hello World"),
                HyperframesParameter(id: "color", name: "Accent Color", type: .color, defaultValue: "#ff0077")
            ]
        )

        let design = DesignSpec(
            palette: DesignSpec.Palette(
                background: TextStyle.RGBA(hex: "#0a0a0a"),
                text: TextStyle.RGBA(hex: "#f0f0f0"),
                primary: TextStyle.RGBA(hex: "#00eeff")
            ),
            typography: DesignSpec.Typography(displayFont: "Impact", bodyFont: "Helvetica")
        )

        let html = HyperframesCatalogWrapper.generateTemplateHTML(
            for: spec,
            parameters: ["title": "Custom Launch"],
            designSpec: design
        )

        #expect(html.contains("Custom Launch"))
        #expect(html.localizedCaseInsensitiveContains("--bg: #0a0a0a"))
        #expect(html.localizedCaseInsensitiveContains("--text: #f0f0f0"))
        #expect(html.contains("\"Impact\""))
    }

    @Test func verifyBlockIntegrityDetectsMissingAssets() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let existingFile = tempDir.appendingPathComponent("present.png")
        try Data([1, 2, 3]).write(to: existingFile)

        let block = HyperframesBlock(
            id: "test-integrity",
            name: "Integrity Test",
            category: "effects",
            path: "block.json",
            assets: ["present.png", "missing.png"]
        )

        let missing = await HyperframesCatalogWrapper.verifyBlockIntegrity(block: block, mirrorRoot: tempDir)
        #expect(missing == ["missing.png"])
    }
}
