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

    /// F1: preflight must check the PROJECT's engine slot — a transcript cached under a whisper override
    /// makes preflight skip re-transcribing for whisper, but still request it for a different engine
    /// (so the override neither re-transcribes what it already has nor reads another engine's slot).
    @Test func preflightRespectsProjectEngineSlot() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("preflight-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.mov")
        try Data("media".utf8).write(to: url)
        let key = try seedTranscript(text: "hello", for: url, engine: .whisper)
        defer { try? FileManager.default.removeItem(at: TranscriptCache.diskURL(key)) }

        func needsTranscript(_ engine: LocalSpeechEngine) async -> Bool {
            let request = SearchIndexCoordinator.PreflightRequest(url: url, type: .video, hasAudio: true, spec: spec, engine: engine)
            return await Task.detached { SearchIndexCoordinator.preflight(request) }.value.needsTranscript
        }
        #expect(await needsTranscript(.whisper) == false) // already cached in this project's slot → no re-transcribe
        #expect(await needsTranscript(.qwen3) == true)     // different engine → its slot is empty
    }
}

@Suite("TranscriptSearch — engine slot")
struct TranscriptSearchEngineTests {
    @Test func spokenSearchReadsProjectEngineSlot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.mov")
        try Data("media".utf8).write(to: url)
        let key = try seedTranscript(text: "the quick brown fox", for: url, engine: .whisper)
        defer { try? FileManager.default.removeItem(at: TranscriptCache.diskURL(key)) }

        let assets = [(id: "a1", url: url)]
        // Reading the project's whisper slot finds the transcript; the global-default slot is empty.
        #expect(TranscriptSearch.search(query: "brown", assets: assets, engine: .whisper).count == 1)
        #expect(TranscriptSearch.search(query: "brown", assets: assets, engine: .qwen3).isEmpty)
    }
}

/// Seeds a single-segment transcript on disk under `engine`'s local cache slot; returns its key.
@discardableResult
private func seedTranscript(text: String, for url: URL, engine: LocalSpeechEngine) throws -> String {
    let key = try #require(TranscriptCache.key(for: url, variant: .local(engine: engine)))
    let result = TranscriptionResult(
        text: text, language: "en",
        words: [], segments: [TranscriptionSegment(text: text, start: 0, end: 1)],
        model: engine.modelId
    )
    try FileManager.default.createDirectory(at: TranscriptCache.directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(result).write(to: TranscriptCache.diskURL(key))
    return key
}
