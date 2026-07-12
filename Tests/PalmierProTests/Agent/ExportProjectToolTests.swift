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

    @Test func handlesDestinationsAndQueue() async throws {
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
        try await waitForJob(from: unique, in: h.exportQueue)

        let blocker = try h.exportQueue.enqueueForTesting(
            outputURL: FileManager.default.temporaryDirectory.appendingPathComponent("export-blocker-\(UUID().uuidString).mov")
        ) { _ in
            try? await Task.sleep(for: .seconds(30))
        }
        let uiActiveVideo = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tool-ui-active-\(UUID().uuidString).mp4")
        let uiActiveResult = try await h.runOK("export_project", args: [
            "mode": "video",
            "outputPath": uiActiveVideo.path,
        ]) as? [String: Any]
        #expect(uiActiveResult?["status"] as? String == "queued")
        #expect(uiActiveResult?["queuePosition"] as? Int == 1)
        if let rawID = uiActiveResult?["jobId"] as? String, let id = UUID(uuidString: rawID) {
            h.exportQueue.cancel(id)
        }
        h.exportQueue.cancel(blocker.jobID)
        #expect(!FileManager.default.fileExists(atPath: uiActiveVideo.path))
    }

    @Test func exportsXMLForANonActiveTimelineById() async throws {
        let h = ToolHarness()
        var other = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(mediaRef: "missing", start: 0, duration: 42)])])
        other.name = "B-Roll Cut"
        h.editor.timelines.append(other)
        let activeBefore = h.editor.activeTimelineId

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tool-tl-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: out) }

        let result = try await h.runOK("export_project", args: [
            "mode": "xml", "outputPath": out.path,
            "timelineId": String(other.id.prefix(8)),
        ]) as? [String: Any]
        #expect(result?["timeline"] as? String == "B-Roll Cut")
        #expect(result?["durationFrames"] as? Int == 42)
        // Exporting by id doesn't switch the active timeline.
        #expect(h.editor.activeTimelineId == activeBefore)
        try await waitForJob(from: result, in: h.exportQueue)
        let xml = String(decoding: try Data(contentsOf: out), as: UTF8.self)
        #expect(xml.contains("<name>B-Roll Cut</name>"))

        let unknown = await h.runRaw("export_project", args: ["mode": "xml", "outputPath": "/tmp/x.xml", "timelineId": "ffffffff"])
        #expect(unknown.isError)
        let palmier = await h.runRaw("export_project", args: ["mode": "palmier", "outputPath": "/tmp/x.palmier", "timelineId": String(other.id.prefix(8))])
        #expect(palmier.isError)
        #expect(ToolHarness.textOf(palmier).contains("palmier"))
    }

    @Test func exportsXML() async throws {
        var nestedClip = Fixtures.clip(mediaRef: "missing", start: 0, duration: 30)
        nestedClip.sourceClipType = .sequence
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [nestedClip]),
        ]))
        let xmlURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tool-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: xmlURL) }
        let xml = try await h.runOK("export_project", args: [
            "mode": "xml",
            "outputPath": xmlURL.path,
        ]) as? [String: Any]
        #expect(["started", "queued"].contains(xml?["status"] as? String ?? ""))
        #expect(xml?["mode"] as? String == "xml")
        #expect((xml?["warnings"] as? [String])?.count == 1)
        try await waitForJob(from: xml, in: h.exportQueue)
        #expect(try String(contentsOf: xmlURL, encoding: .utf8).contains("<xmeml version=\"4\">"))

        h.editor.mediaManifest.entries = [MediaManifestEntry(
            id: "missing", name: "Missing", type: .video,
            source: .external(absolutePath: "/tmp/missing-\(UUID().uuidString).mov"), duration: 1
        )]
        let palmierURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tool-\(UUID().uuidString).palmier")
        defer { try? FileManager.default.removeItem(at: palmierURL) }
        let palmier = try await h.runOK("export_project", args: [
            "mode": "palmier", "outputPath": palmierURL.path,
        ]) as? [String: Any]
        try await waitForJob(from: palmier, in: h.exportQueue)
        let listed = try await h.runOK("manage_exports", args: ["action": "list"]) as? [String: Any]
        let export = (listed?["exports"] as? [[String: Any]])?.first
        #expect((export?["warnings"] as? [String])?.count == 1)
        let report = export?["result"] as? [String: Any]
        #expect((report?["missingMedia"] as? [[String: Any]])?.count == 1)
    }

    @Test func managesCurrentProjectExports() async throws {
        let h = ToolHarness()
        let projectID = h.editor.exportQueueProjectID
        let active = try h.exportQueue.enqueueForTesting(
            outputURL: temporaryExportURL("active"),
            projectID: projectID
        ) { _ in
            try? await Task.sleep(for: .seconds(30))
        }
        let waiting = try h.exportQueue.enqueueForTesting(
            outputURL: temporaryExportURL("waiting"),
            projectID: projectID
        ) { _ in }
        let other = try h.exportQueue.enqueueForTesting(
            outputURL: temporaryExportURL("other"),
            projectID: "another-project"
        ) { _ in }

        let listed = try await h.runOK("manage_exports", args: ["action": "list"]) as? [String: Any]
        let exports = try #require(listed?["exports"] as? [[String: Any]])
        #expect(exports.map { $0["jobId"] as? String } == [waiting.jobID.uuidString, active.jobID.uuidString])
        #expect(exports.first?["status"] as? String == "queued")
        #expect(exports.first?["queuePosition"] as? Int == 1)

        let removed = try await h.runOK("manage_exports", args: [
            "action": "cancel", "jobId": waiting.jobID.uuidString,
        ]) as? [String: Any]
        #expect(removed?["status"] as? String == "removed")
        #expect(h.exportQueue.jobs.first(where: { $0.id == waiting.jobID })?.status == .canceled)

        let canceling = try await h.runOK("manage_exports", args: [
            "action": "cancel", "jobId": active.jobID.uuidString,
        ]) as? [String: Any]
        #expect(canceling?["status"] as? String == "canceling")
        h.exportQueue.cancel(other.jobID)
    }

    private func temporaryExportURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("manage-exports-\(name)-\(UUID().uuidString).mov")
    }

    private func waitForJob(from result: [String: Any]?, in queue: ExportQueue) async throws {
        let rawID = try #require(result?["jobId"] as? String)
        let id = try #require(UUID(uuidString: rawID))
        for _ in 0..<1_000 {
            if let status = queue.jobs.first(where: { $0.id == id })?.status, status.isFinished {
                #expect(status == .completed)
                return
            }
            await Task.yield()
        }
        Issue.record("Export job did not finish")
    }
}
