import Foundation
import Testing
@testable import PalmierPro

@Suite("SearchIndexCoordinator — transcript gating")
@MainActor
struct TranscriptGatingTests {
    private func asset(type: ClipType, hasAudio: Bool) -> MediaAsset {
        let a = MediaAsset(url: URL(fileURLWithPath: "/tmp/x.mov"), type: type, name: "x", duration: 5)
        a.hasAudio = hasAudio
        return a
    }

    @Test func wantsTranscriptOnlyForAudioBearingMedia() {
        #expect(SearchIndexCoordinator.wantsTranscript(asset(type: .video, hasAudio: true)))
        #expect(SearchIndexCoordinator.wantsTranscript(asset(type: .audio, hasAudio: false)))
        #expect(!SearchIndexCoordinator.wantsTranscript(asset(type: .video, hasAudio: false)))
        #expect(!SearchIndexCoordinator.wantsTranscript(asset(type: .image, hasAudio: false)))
    }

    @Test func hasCachedOnDiskFalseForUncachedFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("no-\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!TranscriptCache.hasCachedOnDisk(for: url))
    }
}

@Suite("SearchIndexCoordinator — disk preflight")
struct SearchIndexPreflightTests {
    private let spec = VisualEmbedder.Spec(
        model: "preflight-test",
        version: 1,
        embeddingDim: 4,
        imageSize: 8,
        contextLength: 8
    )

    @Test func visualAndTranscriptEligibilityAreComputedTogether() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("preflight-\(UUID().uuidString).mov")
        try Data("media".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let request = SearchIndexCoordinator.PreflightRequest(
            url: url,
            type: .video,
            hasAudio: true,
            spec: spec
        )
        let result = await Task.detached { SearchIndexCoordinator.preflight(request) }.value

        #expect(result.needsVisual)
        #expect(result.needsTranscript)
        #expect(result.needsIndex)
    }

    @Test func imagePreflightDoesNotRequestTranscript() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("preflight-\(UUID().uuidString).png")
        try Data("image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let request = SearchIndexCoordinator.PreflightRequest(
            url: url,
            type: .image,
            hasAudio: true,
            spec: spec
        )
        let result = await Task.detached { SearchIndexCoordinator.preflight(request) }.value

        #expect(result.needsVisual)
        #expect(!result.needsTranscript)
    }
}
