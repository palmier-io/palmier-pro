import CryptoKit
import Foundation

/// Disk + memory cache for full-file transcripts, keyed by file identity so edits invalidate naturally.
/// Only full transcripts are cached. Windowed requests are served by filtering a cached full transcript.
actor TranscriptCache {
    static let shared = TranscriptCache()

    private var memory: [String: TranscriptionResult] = [:]
    private static let memoryMax = 4

    func transcript(for url: URL, isVideo: Bool, range: ClosedRange<Double>?, preferredLocale: Locale? = nil) async throws -> TranscriptionResult {
        // When a locale is forced, bypass the cache — locale variants must not overwrite the auto-detected entry.
        if let preferredLocale {
            return isVideo
                ? try await Transcription.transcribeVideoAudio(videoURL: url, preferredLocale: preferredLocale, sourceRange: range)
                : try await Transcription.transcribe(fileURL: url, preferredLocale: preferredLocale, sourceRange: range)
        }
        let key = Self.key(for: url)
        if let key, let full = cached(key) {
            return range.map { Self.filter(full, to: $0) } ?? full
        }
        if let range {
            return isVideo
                ? try await Transcription.transcribeVideoAudio(videoURL: url, sourceRange: range)
                : try await Transcription.transcribe(fileURL: url, sourceRange: range)
        }
        let full = isVideo
            ? try await Transcription.transcribeVideoAudio(videoURL: url)
            : try await Transcription.transcribe(fileURL: url)
        if let key { store(full, key: key) }
        return full
    }

    static func filter(_ r: TranscriptionResult, to range: ClosedRange<Double>) -> TranscriptionResult {
        let segments = r.segments.filter { $0.end > range.lowerBound && $0.start < range.upperBound }
        let words = r.words.filter { w in
            guard let s = w.start, let e = w.end else { return false }
            return e > range.lowerBound && s < range.upperBound
        }
        return TranscriptionResult(
            text: segments.map(\.text).joined(separator: " "),
            language: r.language, words: words, segments: segments
        )
    }

    private func cached(_ key: String) -> TranscriptionResult? {
        if let r = memory[key] { return r }
        guard let data = try? Data(contentsOf: Self.diskURL(key)),
              let r = try? JSONDecoder().decode(TranscriptionResult.self, from: data) else { return nil }
        remember(r, key: key)
        return r
    }

    private func store(_ result: TranscriptionResult, key: String) {
        remember(result, key: key)
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(result) {
            try? data.write(to: Self.diskURL(key))
        }
    }

    private func remember(_ result: TranscriptionResult, key: String) {
        if memory.count >= Self.memoryMax { memory.removeAll() }
        memory[key] = result
    }

    private static let directory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(Log.subsystem)/Transcripts", isDirectory: true)

    private static func diskURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    nonisolated static func hasCachedOnDisk(for url: URL) -> Bool {
        guard let key = key(for: url) else { return false }
        return FileManager.default.fileExists(atPath: diskURL(key).path)
    }

    /// Disk-only read
    nonisolated static func cachedOnDisk(for url: URL) -> TranscriptionResult? {
        guard let key = key(for: url),
              let data = try? Data(contentsOf: diskURL(key)) else { return nil }
        return try? JSONDecoder().decode(TranscriptionResult.self, from: data)
    }

    private static func key(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let identity = "\(url.path)|\(mtime.timeIntervalSince1970)|\(size)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
}
