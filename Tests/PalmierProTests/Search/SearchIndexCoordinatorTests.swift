import Foundation
import Testing
@testable import PalmierPro

@Suite("TranscriptCache — disk state")
struct TranscriptCacheDiskTests {
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

    @Test func transcriptEligibilityMatchesMediaAudio() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("preflight-gating-\(UUID().uuidString).mov")
        try Data("media".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let cases: [(type: ClipType, hasAudio: Bool, expected: Bool)] = [
            (.video, true, true),
            (.audio, false, true),
            (.video, false, false),
            (.image, true, false),
        ]
        for testCase in cases {
            let request = SearchIndexCoordinator.PreflightRequest(
                url: url,
                type: testCase.type,
                hasAudio: testCase.hasAudio,
                spec: spec
            )
            let result = await Task.detached { SearchIndexCoordinator.preflight(request) }.value
            #expect(result.needsTranscript == testCase.expected)
        }
    }

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
