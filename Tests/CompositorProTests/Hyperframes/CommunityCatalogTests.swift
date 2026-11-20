import Foundation
import Testing
@testable import CompositorPro

@Suite("Community catalog and cross-platform CLI")
struct CommunityCatalogTests {

    @Test func validatesAndInstallsCommunityTemplate() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let catalog = HyperframesCommunityCatalog(rootDirectory: tempDir)

        let spec = HyperframesBlockSpec(
            id: "custom-lower-third",
            name: "Custom Lower Third",
            category: "Overlays",
            defaultDurationFrames: 90
        )
        let html = "<div class='lower-third'>Hello</div>"

        let installed = try await catalog.installTemplate(spec: spec, html: html)
        #expect(installed.id == "custom-lower-third")
        #expect(installed.name == "Custom Lower Third")

        let loaded = catalog.loadCommunityBlocks()
        #expect(loaded.contains { $0.id == "custom-lower-third" })

        let specLoaded = catalog.loadCommunityBlockSpec(id: "custom-lower-third")
        #expect(specLoaded?.htmlTemplate == html)

        try await catalog.uninstallTemplate(id: "custom-lower-third")
        #expect(!catalog.loadCommunityBlocks().contains { $0.id == "custom-lower-third" })
    }

    @Test func validationFlagsInvalidTemplates() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let catalog = HyperframesCommunityCatalog(rootDirectory: tempDir)

        // Nonexistent
        let nonexistent = tempDir.appendingPathComponent("missing")
        let issues = try await catalog.validateTemplate(at: nonexistent)
        #expect(issues.contains { $0.severity == .error })

        // Empty spec
        let emptySpecURL = tempDir.appendingPathComponent("template.json")
        try "{}".write(to: emptySpecURL, atomically: true, encoding: .utf8)
        let decodeIssues = try await catalog.validateTemplate(at: emptySpecURL)
        #expect(decodeIssues.contains { $0.severity == .error })
    }

    @Test func cliCatalogCommands() async throws {
        let listOut = try await CLIHandler.handleCatalog(["list"])
        #expect(listOut.contains("Extended Catalog"))

        let helpOut = CLIHandler.helpText()
        #expect(helpOut.contains("catalog <action>"))
        #expect(helpOut.contains("export-job"))
    }
}

