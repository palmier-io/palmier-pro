import Foundation
import Testing
@testable import PalmierPro

@Suite("add_captions subtitleMediaRef")
@MainActor
struct AddCaptionsSubtitleTests {
    /// Registers a subtitle asset backed by a real temp file; returns its directory for cleanup.
    private func registerSubtitleAsset(_ h: ToolHarness, id: String, contents: String) async throws -> URL {
        let dir = try await Task.detached {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("AddCaptionsSubtitleTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try contents.write(to: dir.appendingPathComponent("captions.srt"), atomically: true, encoding: .utf8)
            return dir
        }.value
        let url = dir.appendingPathComponent("captions.srt")
        let asset = MediaAsset(id: id, url: url, type: .subtitle, name: "captions", duration: 4)
        h.editor.mediaAssets.append(asset)
        h.editor.mediaManifest.entries.append(MediaManifestEntry(
            id: id, name: asset.name, type: .subtitle,
            source: .external(absolutePath: url.path), duration: 4
        ))
        return dir
    }

    private func removeDirectory(_ dir: URL) async {
        await Task.detached { try? FileManager.default.removeItem(at: dir) }.value
    }

    @Test func placesSubtitleCuesAsCaptionsAtTheirTimecodesResolvingShortIds() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack()]))
        let dir = try await registerSubtitleAsset(
            h, id: "AB107A6F-155C-417C-8776-41BFA1C3DF07",
            contents: "1\n00:00:01,000 --> 00:00:02,000\nHello.\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld.\n"
        )
        defer { Task { await removeDirectory(dir) } }

        // get_media hands out 8-character id prefixes; the tool must expand them.
        _ = try await h.runOK("add_captions", args: ["subtitleMediaRef": "AB107A6F"])

        let captions = h.editor.timeline.tracks[0].clips
        #expect(captions.map(\.textContent) == ["Hello.", "World."])
        #expect(captions.map(\.startFrame) == [30, 90])
        #expect(captions.allSatisfy { $0.captionGroupId != nil })
    }

    @Test func rejectsCombinedOptionsWrongTypesAndMalformedFiles() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack()]))
        h.addAsset(id: "vid", type: .video)
        let dir = try await registerSubtitleAsset(h, id: "bad", contents: "garbage --> nonsense\nBroken.\n")
        defer { Task { await removeDirectory(dir) } }

        let combined = await h.runRaw("add_captions", args: ["subtitleMediaRef": "bad", "maxWords": 3])
        #expect(ToolHarness.textOf(combined).contains("maxWords"))

        // A non-string value must fail, not fall through to transcription.
        let nonString = await h.runRaw("add_captions", args: ["subtitleMediaRef": 123])
        #expect(ToolHarness.textOf(nonString).contains("subtitleMediaRef"))

        let wrongType = await h.runRaw("add_captions", args: ["subtitleMediaRef": "vid"])
        #expect(ToolHarness.textOf(wrongType).contains("not a subtitle file"))

        let malformed = await h.runRaw("add_captions", args: ["subtitleMediaRef": "bad"])
        #expect(ToolHarness.textOf(malformed).contains("Malformed cue timing at line 1"))

        #expect(h.editor.timeline.tracks.flatMap(\.clips).allSatisfy { $0.mediaType != .text })
    }

    @Test func importsSubtitleBytesViaMimeType() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-import-subtitle-bytes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let h = ToolHarness()
        h.editor.projectURL = root.appendingPathComponent("Import.palmier", isDirectory: true)

        let srt = "1\n00:00:01,000 --> 00:00:02,000\nFrom bytes.\n"
        let result = try await h.runOK("import_media", args: [
            "source": ["bytes": Data(srt.utf8).base64EncodedString(), "mimeType": "application/x-subrip"],
        ]) as? [String: Any]
        #expect(result?["type"] as? String == "subtitle")
        // Receipts shorten ids to unique prefixes.
        let mediaRef = try #require(result?["mediaRef"] as? String)
        let asset = try #require(h.editor.mediaAssets.first { $0.id.hasPrefix(mediaRef) })
        #expect(asset.type == .subtitle)
    }
}
