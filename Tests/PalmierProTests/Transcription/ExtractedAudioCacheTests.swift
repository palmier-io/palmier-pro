import Foundation
import Testing
@testable import PalmierPro

// The extracted-audio cache: re-transcription must read the persisted 16k mono extraction, keyed
// by source identity, instead of re-demuxing the source — and stay bounded via LRU eviction.
@Suite("Extracted audio cache")
struct ExtractedAudioCacheTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-cache-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFile(_ dir: URL, name: String, bytes: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    @Test func adoptThenCachedRoundTrips() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeFile(dir, name: "source.mov", bytes: 512)
        let temp = try makeFile(dir, name: "extract.caf", bytes: 64)
        let cacheDir = dir.appendingPathComponent("cache", isDirectory: true)

        #expect(ExtractedAudioCache.cached(for: source, in: cacheDir) == nil)
        let adopted = ExtractedAudioCache.adopt(tempURL: temp, for: source, in: cacheDir)
        #expect(adopted != temp)
        #expect(!FileManager.default.fileExists(atPath: temp.path)) // moved, not copied
        #expect(ExtractedAudioCache.cached(for: source, in: cacheDir) == adopted)
    }

    @Test func keyChangesWhenSourceChanges() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeFile(dir, name: "source.mov", bytes: 512)
        let before = try #require(ExtractedAudioCache.url(for: source, in: dir))
        try Data(repeating: 0xCD, count: 1024).write(to: source) // size (and mtime) change
        let after = try #require(ExtractedAudioCache.url(for: source, in: dir))
        #expect(before != after) // an edited source can never serve the stale extraction
    }

    @Test func missingSourceYieldsNoKey() {
        #expect(ExtractedAudioCache.url(for: URL(fileURLWithPath: "/nonexistent/x.mov")) == nil)
    }

    @Test func evictionDropsOldestUntilUnderCap() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (index, name) in ["old.caf", "mid.caf", "new.caf"].enumerated() {
            let url = try makeFile(dir, name: name, bytes: 100)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(1000 + index))], ofItemAtPath: url.path)
        }
        ExtractedAudioCache.evictIfNeeded(cap: 250, in: dir)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(remaining == ["mid.caf", "new.caf"]) // oldest-used evicted first, cap respected
    }
}
