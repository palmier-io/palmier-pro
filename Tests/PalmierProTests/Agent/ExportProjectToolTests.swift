import CoreGraphics
import Foundation
import Testing
@testable import PalmierPro

@Suite("export_project tool", .serialized)
@MainActor
struct ExportProjectToolTests {
    @Test func rejectsInvalidArguments() async {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(mediaRef: "missing", start: 0, duration: 30)]),
        ]))

        let cases: [([String: Any], String)] = [
            (["outputPath": "/tmp/out.mp4", "codec": "VP9"], "codec"),
            (["outputPath": "/tmp/out.mp4", "resolution": "8K"], "resolution"),
            (["mode": "edl", "outputPath": "/tmp/out.xml"], "mode"),
            (["mode": "xml", "codec": "H.264", "outputPath": "/tmp/out.xml"], "codec only applies"),
            (["outputPath": "relative.mp4"], "absolute"),
            (["outputPath": "/tmp/out.mov", "codec": "H.264"], ".mp4"),
        ]

        for (args, message) in cases {
            let result = await h.runRaw("export_project", args: args)
            #expect(result.isError)
            #expect(ToolHarness.textOf(result).contains(message))
        }

        let emptyTimeline = await ToolHarness().runRaw("export_project", args: ["outputPath": "/tmp/out.mp4"])
        #expect(emptyTimeline.isError)
        #expect(ToolHarness.textOf(emptyTimeline).contains("timeline is empty"))
    }

    @Test func handlesDestinationsAndExportGate() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(mediaRef: "missing", start: 0, duration: 30)]),
        ]))

        let existingVideo = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tool-existing-\(UUID().uuidString).mp4")
        try Data("existing".utf8).write(to: existingVideo)
        defer { try? FileManager.default.removeItem(at: existingVideo) }

        let overwriteFalse = await h.runRaw("export_project", args: [
            "outputPath": existingVideo.path,
            "overwrite": false,
        ])
        #expect(overwriteFalse.isError)
        #expect(ToolHarness.textOf(overwriteFalse).contains("already exists"))

        let downloads = try #require(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
        let base = "export-tool-\(UUID().uuidString)"
        h.editor.projectURL = URL(fileURLWithPath: "/tmp/\(base).\(Project.fileExtension)")
        let existingXML = downloads.appendingPathComponent("\(base).xml")
        try Data("existing".utf8).write(to: existingXML)
        defer { try? FileManager.default.removeItem(at: existingXML) }

        let unique = try await h.runOK("export_project", args: ["mode": "xml"]) as? [String: Any]
        let uniquePath = try #require(unique?["path"] as? String)
        let uniqueURL = URL(fileURLWithPath: uniquePath)
        defer { try? FileManager.default.removeItem(at: uniqueURL) }
        #expect(uniqueURL.deletingLastPathComponent().standardizedFileURL == downloads.standardizedFileURL)
        #expect(uniqueURL.lastPathComponent == "\(base) 2.xml")

        #expect(ExportCoordinator.beginExclusiveExportIfIdle())
        defer { ExportCoordinator.endExclusiveExport() }

        let activeXML = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tool-active-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: activeXML) }
        let xmlResult = await h.runRaw("export_project", args: ["mode": "xml", "outputPath": activeXML.path])
        #expect(!xmlResult.isError)
        #expect(FileManager.default.fileExists(atPath: activeXML.path))

        let activeVideo = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tool-active-\(UUID().uuidString).mp4")
        let videoResult = await h.runRaw("export_project", args: ["mode": "video", "outputPath": activeVideo.path])
        #expect(videoResult.isError)
        #expect(ToolHarness.textOf(videoResult).contains("another export"))
        #expect(!FileManager.default.fileExists(atPath: activeVideo.path))
    }

    @Test func exportsVideoXMLAndPalmier() async throws {
        let renderSize = CGSize(width: 320, height: 180)
        let mediaRef = "black-fixture"
        let blackURL = try await ImageVideoGenerator.blackVideo(size: renderSize)
        let clip = Fixtures.clip(id: "c1", mediaRef: mediaRef, start: 0, duration: 30)
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        timeline.width = Int(renderSize.width)
        timeline.height = Int(renderSize.height)

        let h = ToolHarness(timeline: timeline)
        h.editor.mediaManifest.entries = [MediaManifestEntry(
            id: mediaRef,
            name: "black",
            type: .video,
            source: .external(absolutePath: blackURL.path),
            duration: 5.0
        )]

        let videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tool-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let video = try await h.runOK("export_project", args: [
            "mode": "video",
            "outputPath": videoURL.path,
        ]) as? [String: Any]
        #expect(video?["status"] as? String == "exported")
        #expect(video?["codec"] as? String == "H.264")
        #expect(video?["resolution"] as? String == "Match Timeline")
        #expect(video?["width"] as? Int == Int(renderSize.width))
        #expect(video?["height"] as? Int == Int(renderSize.height))
        #expect(FileManager.default.fileExists(atPath: videoURL.path))

        let xmlURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tool-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: xmlURL) }
        let xml = try await h.runOK("export_project", args: [
            "mode": "xml",
            "outputPath": xmlURL.path,
        ]) as? [String: Any]
        #expect(xml?["status"] as? String == "exported")
        #expect(xml?["mode"] as? String == "xml")
        #expect(try String(contentsOf: xmlURL, encoding: .utf8).contains("<xmeml version=\"4\">"))

        h.editor.mediaManifest.entries = [MediaManifestEntry(
            id: "missing-media",
            name: "Missing Media",
            type: .video,
            source: .external(absolutePath: "/tmp/missing-\(UUID().uuidString).mp4"),
            duration: 1.0
        )]
        let palmierURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tool-existing-\(UUID().uuidString).palmier", isDirectory: true)
        let staleURL = palmierURL.appendingPathComponent("stale.txt")
        try FileManager.default.createDirectory(at: palmierURL, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: staleURL)
        defer { try? FileManager.default.removeItem(at: palmierURL) }

        let palmier = try await h.runOK("export_project", args: [
            "mode": "palmier",
            "outputPath": palmierURL.path,
        ]) as? [String: Any]
        let missing = palmier?["missingMedia"] as? [[String: Any]]
        #expect(palmier?["status"] as? String == "exportedWithWarnings")
        #expect(missing?.first?["id"] as? String == "missing-media")
        #expect(!FileManager.default.fileExists(atPath: staleURL.path))
        #expect(FileManager.default.fileExists(atPath: palmierURL.appendingPathComponent(Project.timelineFilename).path))
        #expect(FileManager.default.fileExists(atPath: palmierURL.appendingPathComponent(Project.manifestFilename).path))
    }
}
