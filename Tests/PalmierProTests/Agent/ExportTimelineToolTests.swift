import Foundation
import Testing
@testable import PalmierPro

@Suite("ToolExecutor — export_timeline")
@MainActor
struct ExportTimelineToolTests {

    @Test func xmlExportWritesFileAndReturnsMetadata() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(fps: 24, tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 48)]),
        ]))
        h.editor.timeline.width = 1280
        h.editor.timeline.height = 720
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("palmier-export-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let json = try await h.runOK("export_timeline", args: [
            "outputPath": outURL.path,
            "format": "xml",
        ]) as? [String: Any]

        #expect(FileManager.default.fileExists(atPath: outURL.path))
        #expect(json?["outputPath"] as? String == outURL.path)
        #expect(json?["format"] as? String == "xml")
        #expect(json?["width"] as? Int == 1280)
        #expect(json?["height"] as? Int == 720)
        #expect(json?["fps"] as? Int == 24)
        #expect(json?["totalFrames"] as? Int == 48)
        #expect(json?["durationSeconds"] as? Double == 2.0)
    }

    @Test func refusesExistingOutputWithoutOverwrite() async throws {
        let h = ToolHarness()
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("palmier-existing-\(UUID().uuidString).xml")
        try Data("existing".utf8).write(to: outURL)
        defer { try? FileManager.default.removeItem(at: outURL) }

        let result = await h.runRaw("export_timeline", args: [
            "outputPath": outURL.path,
            "format": "xml",
        ])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("Pass overwrite=true"))
    }

    @Test func rejectsUnsupportedFormatAndResolution() async {
        let h = ToolHarness()

        let badFormat = await h.runRaw("export_timeline", args: [
            "outputPath": "/tmp/export.bad",
            "format": "gif",
        ])
        #expect(badFormat.isError)
        #expect(ToolHarness.textOf(badFormat).contains("Unsupported format"))

        let badResolution = await h.runRaw("export_timeline", args: [
            "outputPath": "/tmp/export.mp4",
            "format": "h264",
            "resolution": "8k",
        ])
        #expect(badResolution.isError)
        #expect(ToolHarness.textOf(badResolution).contains("Unsupported resolution"))
    }

    @Test func palmierProjectExportWritesPackage() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(fps: 30, tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 30)]),
        ]))
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("palmier-package-\(UUID().uuidString).palmier", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outURL) }

        let json = try await h.runOK("export_timeline", args: [
            "outputPath": outURL.path,
            "format": "palmierProject",
        ]) as? [String: Any]

        #expect(FileManager.default.fileExists(atPath: outURL.appendingPathComponent(Project.timelineFilename).path))
        #expect(FileManager.default.fileExists(atPath: outURL.appendingPathComponent(Project.manifestFilename).path))
        #expect(json?["outputPath"] as? String == outURL.path)
        #expect(json?["format"] as? String == "palmierProject")
        #expect(json?["totalFrames"] as? Int == 30)
    }
}
