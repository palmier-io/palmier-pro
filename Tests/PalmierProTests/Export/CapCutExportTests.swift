import Testing
import Foundation
@testable import PalmierPro

@Suite("CapCut export")
struct CapCutExportTests {

    @Test func writesDraftWithMaterialsTracksAndMicroseconds() async throws {
        let video = Fixtures.clip(id: "v1", mediaType: .video, start: 0, duration: 30)
        var text = Fixtures.clip(id: "t1", mediaType: .text, start: 0, duration: 30)
        text.textContent = "Hello"
        text.textStyle = TextStyle()
        let timeline = Fixtures.timeline(fps: 30, tracks: [
            Fixtures.videoTrack(clips: [video]),
            Track(type: .text, clips: [text]),
        ])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let report = try await CapCutExporter.export(
            timeline: timeline,
            resolveURL: { _ in URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).mp4") },
            projectName: "Test",
            outputURL: dir
        )
        #expect(report.videos == 1)
        #expect(report.texts == 1)

        let data = try Data(contentsOf: dir.appendingPathComponent("draft_content.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let canvas = try #require(json["canvas_config"] as? [String: Any])
        #expect(canvas["width"] as? Int == 1920)
        #expect(canvas["height"] as? Int == 1080)
        #expect((json["fps"] as? Double) == 30)
        // 30 frames @ 30 fps = 1,000,000 µs
        #expect(json["duration"] as? Int == 1_000_000)

        let materials = try #require(json["materials"] as? [String: Any])
        #expect((materials["videos"] as? [[String: Any]])?.count == 1)
        #expect((materials["texts"] as? [[String: Any]])?.count == 1)

        let tracks = try #require(json["tracks"] as? [[String: Any]])
        #expect(tracks.count == 2)

        // meta file written too
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("draft_meta_info.json").path))
    }
}
