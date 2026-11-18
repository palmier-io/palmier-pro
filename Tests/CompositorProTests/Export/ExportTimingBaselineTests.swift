import Foundation
import MCP
import Testing
@testable import CompositorPro

/// Fixed-fixture export measurement. Opt-in because a 90-second encode is minutes of work:
/// set COMPOSITOR_EXPORT_BENCH=1 to run and write /tmp/compositor-export-baseline.json.
@Suite("Export timing baseline", .serialized)
@MainActor
struct ExportTimingBaselineTests {
    private func enabled() -> Bool {
        ProcessInfo.processInfo.environment["COMPOSITOR_EXPORT_BENCH"] == "1"
    }

    @Test func ninetySecondFixtureExportCompletesAndRecordsWallClock() async throws {
        guard enabled() else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("export-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let harness = ToolHarness()
        var title = Fixtures.clip(mediaRef: "", mediaType: .text, start: 0, duration: 90 * 30)
        title.textContent = "Benchmark fixture"
        harness.editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [title])])
        harness.editor.timeline.width = 320
        harness.editor.timeline.height = 180

        let server = Server(name: "export-bench", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "export-bench", version: "1")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let output = directory.appendingPathComponent("fixture.mp4")
            let started = ContinuousClock.now
            let queued = try await client.callTool(name: "export_project", arguments: [
                "outputPath": .string(output.path), "codec": .string("h264"), "resolution": .string("Match Timeline"),
            ])
            let queuedText = Self.text(queued.content)
            #expect(queued.isError != true, "\(queuedText)")
            let jobID = try #require(try Self.json(queued.content)["jobId"] as? String)
            let finished = try await client.callTool(name: "manage_exports", arguments: [
                "action": .string("wait"), "jobId": .string(jobID),
            ])
            let finishedText = Self.text(finished.content)
            #expect(try Self.json(finished.content)["status"] as? String == "completed", "\(finishedText)")
            let seconds = Self.seconds(ContinuousClock.now - started)

            let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            #expect(bytes > 0)
            let report: [String: Any] = [
                "fixture": "90s text-only, 320x180, h264, Match Timeline",
                "frames": 90 * 30,
                "wallClockSeconds": seconds,
                "outputBytes": bytes,
                "machine": ProcessInfo.processInfo.hostName,
                "recordedAt": ISO8601DateFormatter().string(from: Date()),
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: "/tmp/compositor-export-baseline.json"))
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func text(_ content: [Tool.Content]) -> String {
        content.compactMap {
            if case .text(let value, _, _) = $0 { return value }
            return nil
        }.joined(separator: "\n")
    }

    private static func json(_ content: [Tool.Content]) throws -> [String: Any] {
        let raw = text(content)
        return (try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]) ?? [:]
    }
}
