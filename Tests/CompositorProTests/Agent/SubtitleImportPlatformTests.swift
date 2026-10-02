import Foundation
import Testing
@testable import CompositorPro

@Suite("Subtitle import placement")
@MainActor
struct SubtitleImportPlatformTests {
    private func registerSubtitle(_ harness: ToolHarness, id: String = "subs") async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subs-\(UUID().uuidString).srt")
        let contents = """
        1
        00:00:01,000 --> 00:00:02,000
        Hello.

        2
        00:00:03,000 --> 00:00:04,000
        World.
        """
        try await Task.detached { try contents.write(to: url, atomically: true, encoding: .utf8) }.value
        harness.editor.mediaAssets.append(
            MediaAsset(id: id, url: url, type: .subtitle, name: "captions", duration: 4)
        )
        harness.editor.mediaManifest.entries.append(MediaManifestEntry(
            id: id, name: "captions", type: .subtitle,
            source: .external(absolutePath: url.path), duration: 4
        ))
        return url
    }

    private func captions(_ harness: ToolHarness) -> [Clip] {
        harness.editor.timeline.tracks.flatMap(\.clips).filter { $0.captionGroupId != nil }
    }

    private func centreY(_ harness: ToolHarness) throws -> Double {
        try #require(captions(harness).first).transform.centerY
    }

    @Test("An imported subtitle keeps the historic placement by default")
    func defaultIsUnchanged() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack()]))
        let url = try await registerSubtitle(harness)
        defer { Task { try? FileManager.default.removeItem(at: url) } }
        _ = try await harness.runOK("add_captions", args: ["subtitleMediaRef": "subs"])
        #expect(abs(try centreY(harness) - 0.90) < 1e-9)
    }

    @Test("A platform lifts an imported subtitle clear of its interface")
    func platformMovesImportedCaptions() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack()]))
        let url = try await registerSubtitle(harness)
        defer { Task { try? FileManager.default.removeItem(at: url) } }
        _ = try await harness.runOK("add_captions", args: [
            "subtitleMediaRef": "subs", "platform": "tiktokShorts",
        ])
        let centre = try centreY(harness)
        #expect(centre < 0.90, "Shorts reserves the bottom fifth")
        #expect(centre <= DeliveryPlatform.tiktokShorts.coveredArea.captionSafeRect.maxY)
    }

    @Test("The file's own text and timing are still honoured")
    func fileContentIsUntouched() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack()]))
        let url = try await registerSubtitle(harness)
        defer { Task { try? FileManager.default.removeItem(at: url) } }
        _ = try await harness.runOK("add_captions", args: [
            "subtitleMediaRef": "subs", "platform": "instagramReels",
        ])
        let clips = captions(harness)
        #expect(clips.map(\.textContent) == ["Hello.", "World."])
        #expect(clips.map(\.startFrame) == [30, 90])
    }

    @Test("platform is still accepted alone, and other styling options still are not")
    func onlyPlacementIsAllowedAlongside() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack()]))
        let url = try await registerSubtitle(harness)
        defer { Task { try? FileManager.default.removeItem(at: url) } }

        let allowed = await harness.runRaw("add_captions", args: [
            "subtitleMediaRef": "subs", "platform": "youtube",
        ])
        #expect(allowed.isError == false, ToolHarness.textOf(allowed))

        let refused = await harness.runRaw("add_captions", args: [
            "subtitleMediaRef": "subs", "maxWords": 4,
        ])
        #expect(refused.isError, "restyling the file's captions is still refused")
    }

    @Test("An unknown platform is refused and nothing is imported")
    func unknownPlatformRefused() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack()]))
        let url = try await registerSubtitle(harness)
        defer { Task { try? FileManager.default.removeItem(at: url) } }
        let result = await harness.runRaw("add_captions", args: [
            "subtitleMediaRef": "subs", "platform": "tiktok",
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("tiktokShorts"))
        #expect(captions(harness).isEmpty)
    }

    @Test("The UI path still defaults to unencumbered placement")
    func uiPathDefaultsToGeneric() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack()]))
        let url = try await registerSubtitle(harness)
        defer { Task { try? FileManager.default.removeItem(at: url) } }
        _ = try await harness.importCaptions(from: url)
        #expect(abs(try centreY(harness) - 0.90) < 1e-9)
    }
}