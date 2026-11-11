import Testing
import Foundation
@testable import CompositorPro

@Suite("CLI Handler Tests")
struct CLIHandlerTests {

    @Test func isCLIInvocationDetectsCommandsAccurately() {
        #expect(CLIHandler.isCLIInvocation(["CompositorPro", "init"]))
        #expect(CLIHandler.isCLIInvocation(["CompositorPro", "preview", "my-project.compositorpro"]))
        #expect(CLIHandler.isCLIInvocation(["CompositorPro", "render", "my-project.compositorpro"]))
        #expect(CLIHandler.isCLIInvocation(["CompositorPro", "hyperframes", "catalog"]))
        #expect(CLIHandler.isCLIInvocation(["CompositorPro", "help"]))
        #expect(CLIHandler.isCLIInvocation(["CompositorPro", "--help"]))
        #expect(CLIHandler.isCLIInvocation(["CompositorPro", "version"]))

        #expect(!CLIHandler.isCLIInvocation(["CompositorPro"]))
        #expect(!CLIHandler.isCLIInvocation(["CompositorPro", "-NSDocumentRevisionsDebugMode"]))
        #expect(!CLIHandler.isCLIInvocation(["CompositorPro", "-psn_0_123456"]))
    }

    @Test func initScaffoldsProjectPackage() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = try await CLIHandler.handleInit([
            "MyCLIProject",
            "--path", tempDir.path,
            "--fps", "60",
            "--width", "3840",
            "--height", "2160",
            "--template"
        ])

        #expect(result.contains("Successfully created project 'MyCLIProject'"))

        let packageURL = tempDir.appendingPathComponent("MyCLIProject.compositorpro")
        let projectJsonURL = packageURL.appendingPathComponent("project.json")
        let storyboardURL = packageURL.appendingPathComponent("STORYBOARD.md")

        #expect(FileManager.default.fileExists(atPath: projectJsonURL.path))
        #expect(FileManager.default.fileExists(atPath: storyboardURL.path))

        let data = try Data(contentsOf: projectJsonURL)
        let project = try ProjectFile.decode(data)
        #expect(project.timelines.count == 1)
        let timeline = try #require(project.timelines.first)
        #expect(timeline.name == "MyCLIProject")
        #expect(timeline.fps == 60)
        #expect(timeline.width == 3840)
        #expect(timeline.height == 2160)
        #expect(timeline.tracks.count == 2)
    }

    @Test func hyperframesCLICatalogInspectAndHTML() async throws {
        let catalogOutput = try await CLIHandler.handleHyperframes(["catalog"])
        #expect(catalogOutput.contains("HyperFrames Catalog"))
        #expect(catalogOutput.contains("kinetic-title-reveal"))

        let inspectOutput = try await CLIHandler.handleHyperframes(["inspect", "kinetic-title-reveal"])
        #expect(inspectOutput.contains("\"id\" : \"kinetic-title-reveal\""))
        #expect(inspectOutput.contains("\"parameters\""))

        let htmlOutput = try await CLIHandler.handleHyperframes(["html", "kinetic-title-reveal", "--title", "CLI Demo"])
        #expect(htmlOutput.contains("CLI Demo"))
        #expect(htmlOutput.contains("<!DOCTYPE html>"))
    }

    private final class OutputBox: @unchecked Sendable {
        var lines: [String] = []
        func append(_ line: String) { lines.append(line) }
    }

    @Test func runHandlesHelpAndInvalidCommandsGracefully() async {
        let outputBox = OutputBox()
        let errorBox = OutputBox()

        let helpCode = await CLIHandler.run(["CompositorPro", "help"], printOut: { outputBox.append($0) }, printErr: { errorBox.append($0) })
        #expect(helpCode == 0)
        #expect(outputBox.lines.contains { $0.contains("CompositorPro CLI") })

        let unknownCode = await CLIHandler.run(["CompositorPro", "nonexistent"], printOut: { _ in }, printErr: { errorBox.append($0) })
        #expect(unknownCode == 1)
        #expect(errorBox.lines.contains { $0.contains("Unknown subcommand") })
    }
}
