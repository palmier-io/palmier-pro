import CryptoKit
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

    @Test func cachedTranscriptFindsLocaleKeyedCloudFull() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-lang-\(UUID().uuidString).wav")
        try Data("audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = try #require(attributes[.size] as? NSNumber).int64Value
        let mtime = try #require(attributes[.modificationDate] as? Date)
        let base = "\(url.path)|\(mtime.timeIntervalSince1970)|\(size)"
        func cacheURL(prefix: String) -> URL {
            let key = SHA256.hash(data: Data("\(prefix)|\(base)".utf8))
                .map { String(format: "%02x", $0) }.joined().prefix(32)
            return TranscriptCache.directory.appendingPathComponent("\(key).json")
        }
        let legacyURL = cacheURL(prefix: "cloud|en|full")
        let lookupURL = cacheURL(prefix: "cloud|any|full")
        defer {
            try? FileManager.default.removeItem(at: legacyURL)
            try? FileManager.default.removeItem(at: lookupURL)
        }
        try FileManager.default.createDirectory(at: TranscriptCache.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(full).write(to: legacyURL)

        let cached = await TranscriptCache.shared.cachedTranscript(for: url)
        #expect(cached?.text == full.text)
        #expect(cached?.language == full.language)
    }

    @Test func cachedTranscriptFindsRangedCloudResult() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-range-\(UUID().uuidString).wav")
        try Data("audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await TranscriptCache.shared.storeCloudTranscript(
            full,
            for: url,
            range: 4...12,
            language: "en"
        )
        let cached = await TranscriptCache.shared.cachedTranscript(for: url)
        #expect(cached?.text == full.text)
    }

    @Test func rangedCloudResultDoesNotReplaceFullLookup() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-full-range-\(UUID().uuidString).wav")
        try Data("audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let partial = TranscriptionResult(
            text: "How are you.",
            language: "en-US",
            words: Array(full.words[2...4]),
            segments: [full.segments[1]]
        )

        await TranscriptCache.shared.storeCloudTranscript(
            full, for: url, range: nil, language: "en"
        )
        await TranscriptCache.shared.storeCloudTranscript(
            partial, for: url, range: 4...6, language: "en"
        )
        let cached = await TranscriptCache.shared.cachedTranscript(for: url)
        #expect(cached?.text == full.text)
    }

    @Test func storeCloudTranscriptPostsDidStoreNotification() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-notify-\(UUID().uuidString).wav")
        try Data("audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let expectedPath = url.path
        await confirmation("transcriptCacheDidStore") { confirm in
            let token = NotificationCenter.default.addObserver(
                forName: .transcriptCacheDidStore,
                object: nil,
                queue: nil
            ) { notification in
                guard let stored = notification.object as? URL, stored.path == expectedPath else { return }
                confirm()
            }
            defer { NotificationCenter.default.removeObserver(token) }
            await TranscriptCache.shared.storeCloudTranscript(
                full,
                for: url,
                range: nil,
                language: "en"
            )
        }
    }
}
