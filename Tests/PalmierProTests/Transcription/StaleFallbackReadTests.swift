import Foundation
import Testing
@testable import PalmierPro

// Stale-fallback reads (spoken search sees a prior engine tag after a bump), the grace-bounded
// non-blocking read path, and the get_transcript pending/indexing response shape.

/// Seeds a single-segment transcript on disk under an explicit cache variant; returns its key.
@discardableResult
private func seed(_ text: String, for url: URL, variant: TranscriptCache.CacheVariant) throws -> String {
    let key = try #require(TranscriptCache.key(for: url, variant: variant))
    let result = TranscriptionResult(
        text: text, language: "en", words: [],
        segments: [TranscriptionSegment(text: text, start: 0, end: 1)], model: "seed")
    try FileManager.default.createDirectory(at: TranscriptCache.directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(result).write(to: TranscriptCache.diskURL(key))
    return key
}

private func tempMediaURL() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("stale-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("clip.mov")
    try Data("media".utf8).write(to: url)
    return url
}

@Suite("Stale-fallback reads")
struct StaleFallbackReadTests {
    @Test func currentTagWinsAndIsNotStale() throws {
        let url = try tempMediaURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = try seed("fresh", for: url, variant: .local(engine: .qwen3))
        defer { try? FileManager.default.removeItem(at: TranscriptCache.diskURL(key)) }

        let read = try #require(TranscriptCache.cachedOnDiskAllowingStale(for: url, engine: .qwen3))
        #expect(read.stale == false)
        #expect(read.result.segments.first?.text == "fresh")
    }

    @Test func fallsBackToPriorEngineTagMarkedStale() throws {
        let url = try tempMediaURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Only a qw6 entry exists (the bump to qw7 orphaned it); no current-tag slot.
        let key = try seed("legacy", for: url, variant: .localTag("qw6"))
        defer { try? FileManager.default.removeItem(at: TranscriptCache.diskURL(key)) }

        let read = try #require(TranscriptCache.cachedOnDiskAllowingStale(for: url, engine: .qwen3))
        #expect(read.stale == true)
        #expect(read.result.segments.first?.text == "legacy")
        // The strict current-tag reader still sees nothing, so a full read regenerates under qw7.
        #expect(TranscriptCache.cachedOnDisk(for: url, engine: .qwen3) == nil)
    }

    @Test func noEntryReturnsNil() throws {
        let url = try tempMediaURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(TranscriptCache.cachedOnDiskAllowingStale(for: url, engine: .qwen3) == nil)
    }

    @Test func spokenSearchFlagsStaleHits() throws {
        let url = try tempMediaURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = try seed("the quick brown fox", for: url, variant: .localTag("qw6"))
        defer { try? FileManager.default.removeItem(at: TranscriptCache.diskURL(key)) }

        let hits = TranscriptSearch.search(query: "brown", assets: [(id: "a1", url: url)], engine: .qwen3)
        #expect(hits.count == 1)
        #expect(hits.first?.stale == true)
    }
}

@Suite("Grace-bounded non-blocking reads")
struct GraceBoundedReadTests {
    @Test func cachedClipsReturnImmediatelyNoPending() async throws {
        let url = try tempMediaURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = try seed("hello", for: url, variant: .local(engine: .qwen3))
        defer { try? FileManager.default.removeItem(at: TranscriptCache.diskURL(key)) }

        let out = await ToolExecutor.graceBoundedLocalTranscripts(
            urls: [url], isVideoByURL: [url: true], engine: .qwen3, grace: .seconds(5))
        #expect(out.results[url]?.segments.first?.text == "hello")
        #expect(out.pending.isEmpty)
    }

    @Test func scopedReadDoesNotBlockOnSiblingUncachedClips() async throws {
        let cached = try tempMediaURL()
        let sibling = try tempMediaURL()
        defer {
            try? FileManager.default.removeItem(at: cached.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: sibling.deletingLastPathComponent())
        }
        let key = try seed("scoped", for: cached, variant: .local(engine: .qwen3))
        defer { try? FileManager.default.removeItem(at: TranscriptCache.diskURL(key)) }

        // Await only the cached clip; the uncached sibling must not hold the read past its own transcribe.
        let started = ContinuousClock.now
        let out = await ToolExecutor.graceBoundedLocalTranscripts(
            urls: [cached, sibling], isVideoByURL: [cached: true, sibling: false],
            engine: .qwen3, awaitURLs: [cached], grace: .seconds(5))
        #expect(started.duration(to: .now) < .seconds(1)) // returned promptly, not after the 5s grace
        #expect(out.results[cached]?.segments.first?.text == "scoped")
        #expect(out.pending == [sibling])
    }

    @Test func uncachedClipBecomesPendingAfterGrace() async throws {
        let url = try tempMediaURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // No seeded entry; the bogus file can't be transcribed, so it never lands in cache and the
        // read returns it as pending rather than blocking on it.
        let out = await ToolExecutor.graceBoundedLocalTranscripts(
            urls: [url], isVideoByURL: [url: false], engine: .qwen3, grace: .milliseconds(300))
        #expect(out.results.isEmpty)
        #expect(out.pending == [url])
    }
}

@Suite("get_transcript — pending + indexing payload")
struct TranscriptPendingPayloadTests {
    private func word(_ i: Int, clip: String) -> TimelineWord {
        TimelineWord(index: i, clipId: clip, trackIndex: 0, clipStartFrame: 0, clipEndFrame: 300,
                     text: "w\(i)", startFrame: i * 10, endFrame: i * 10 + 5, speaker: nil)
    }

    @Test func pendingAndIndexingSurfaceInPayload() {
        let transcript = TimelineTranscript(
            context: .init(provider: .local, preferredLocale: nil),
            words: [word(0, clip: "c1")],
            skipped: [],
            resolvedModel: "qwen3-asr-0.6B-int8",
            pending: [
                ["clipId": "c2", "mediaRef": "m2", "status": "transcribing"],
                ["clipId": "c3", "mediaRef": "m3", "status": "transcribing"],
            ],
            indexing: (done: 20, total: 293)
        )
        let out = transcript.responsePayload(fps: 30, clipId: nil, startFrame: nil, endFrame: nil, maxWords: 100)
        let pending = out["pending"] as? [[String: Any]]
        #expect(pending?.count == 2)
        let indexing = out["indexing"] as? [String: Int]
        #expect(indexing?["done"] == 20)
        #expect(indexing?["total"] == 293)
        // The cached clip's words are still returned alongside the pending markers.
        #expect((out["clips"] as? [[String: Any]])?.count == 1)
    }

    @Test func pendingIsFilteredToScopedClip() {
        let transcript = TimelineTranscript(
            context: .init(provider: .local, preferredLocale: nil),
            words: [],
            skipped: [],
            resolvedModel: "qwen3-asr-0.6B-int8",
            pending: [
                ["clipId": "c2", "mediaRef": "m2", "status": "transcribing"],
                ["clipId": "c3", "mediaRef": "m3", "status": "transcribing"],
            ]
        )
        let out = transcript.responsePayload(fps: 30, clipId: "c2", startFrame: nil, endFrame: nil, maxWords: 100)
        let pending = out["pending"] as? [[String: Any]]
        #expect(pending?.count == 1)
        #expect(pending?.first?["clipId"] as? String == "c2")
    }

    @Test func noPendingOrIndexingKeysWhenClean() {
        let transcript = TimelineTranscript(
            context: .init(provider: .local, preferredLocale: nil),
            words: [word(0, clip: "c1")],
            skipped: [],
            resolvedModel: "qwen3-asr-0.6B-int8"
        )
        let out = transcript.responsePayload(fps: 30, clipId: nil, startFrame: nil, endFrame: nil, maxWords: 100)
        #expect(out["pending"] == nil)
        #expect(out["indexing"] == nil)
    }
}
