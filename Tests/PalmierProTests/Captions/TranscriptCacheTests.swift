import Foundation
import Testing
@testable import PalmierPro

@Suite("TranscriptCache")
struct TranscriptCacheTests {
    private let full = TranscriptionResult(
        text: "Hello there. How are you. Fine thanks.",
        language: "en-US",
        words: [
            TranscriptionWord(text: "Hello", start: 0.0, end: 0.4),
            TranscriptionWord(text: "there", start: 0.4, end: 0.8),
            TranscriptionWord(text: "How", start: 5.0, end: 5.3),
            TranscriptionWord(text: "are", start: 5.3, end: 5.5),
            TranscriptionWord(text: "you", start: 5.5, end: 5.8),
            TranscriptionWord(text: "Fine", start: 10.0, end: 10.4),
            TranscriptionWord(text: "thanks", start: 10.4, end: 10.9),
        ],
        segments: [
            TranscriptionSegment(text: "Hello there.", start: 0.0, end: 0.8),
            TranscriptionSegment(text: "How are you.", start: 5.0, end: 5.8),
            TranscriptionSegment(text: "Fine thanks.", start: 10.0, end: 10.9),
        ]
    )

    @Test func filterKeepsOnlyOverlappingEntries() {
        let windowed = TranscriptCache.filter(full, to: 4.0...6.0)
        #expect(windowed.segments.map(\.text) == ["How are you."])
        #expect(windowed.words.map(\.text) == ["How", "are", "you"])
        #expect(windowed.text == "How are you.")
        #expect(windowed.language == "en-US")
    }

    @Test func filterIncludesBoundaryStraddlers() {
        let windowed = TranscriptCache.filter(full, to: 0.5...5.2)
        #expect(windowed.segments.map(\.text) == ["Hello there.", "How are you."])
    }

    @Test func resultRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(full)
        let decoded = try JSONDecoder().decode(TranscriptionResult.self, from: data)
        #expect(decoded.text == full.text)
        #expect(decoded.language == full.language)
        #expect(decoded.segments.count == full.segments.count)
        #expect(decoded.words.count == full.words.count)
        #expect(decoded.words[0].start == full.words[0].start)
    }

    // A2: a full-file cloud transcript lives under a .cloud key the local read scheme never reaches.
    // The provider-neutral alias makes it visible to cachedOnDisk so cloud projects can resync.
    @Test func cloudFullTranscriptIsFoundByCacheOnDiskViaAlias() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pp-cloudcache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("clip.wav")
        try Data("audio-bytes".utf8).write(to: file)

        #expect(!TranscriptCache.hasCachedOnDisk(for: file))
        await TranscriptCache.shared.storeCloudTranscript(full, for: file, range: nil, language: "zh")
        await TranscriptCache.shared.clearMemory()  // force the read to come off disk

        #expect(TranscriptCache.hasCachedOnDisk(for: file))
        #expect(TranscriptCache.cachedOnDisk(for: file)?.words.map(\.text) == full.words.map(\.text))
    }

    @Test func windowedCloudTranscriptDoesNotPublishAlias() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pp-cloudcache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("clip.wav")
        try Data("audio-bytes".utf8).write(to: file)

        await TranscriptCache.shared.storeCloudTranscript(full, for: file, range: 4.0...6.0, language: "zh")
        await TranscriptCache.shared.clearMemory()
        // Only the full-file entry is the resync source; a windowed cloud entry must not become the alias.
        #expect(!TranscriptCache.hasCachedOnDisk(for: file))
    }

    // A3: the default (nil cacheTag) transcript() key must not shift when the glossary bias fingerprint
    // changes — otherwise every glossary edit re-transcribes the whole file. Explicit tags still salt.
    @Test func defaultCacheKeyIgnoresBiasFingerprintChurn() {
        let file = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")  // a stable existing file
        TranscriptionBias.update(hotwords: ["OpenAI"], fingerprint: "fp-1")
        defer { TranscriptionBias.update(hotwords: [], fingerprint: "") }

        let a = TranscriptCache.key(for: file, cacheTag: nil)
        TranscriptionBias.update(hotwords: ["OpenAI", "Anthropic"], fingerprint: "fp-2")
        let b = TranscriptCache.key(for: file, cacheTag: nil)

        #expect(a != nil && a == b, "default key is unsalted, so fingerprint churn cannot invalidate it")
        #expect(TranscriptCache.key(for: file, cacheTag: "fp-2") != a, "an explicit cacheTag still salts to a distinct key")
    }
}
