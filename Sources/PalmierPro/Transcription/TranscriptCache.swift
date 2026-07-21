import CryptoKit
import Foundation

/// Disk + memory cache for local and cloud transcripts, keyed by file identity so edits invalidate naturally.
actor TranscriptCache {
    static let shared = TranscriptCache()
    static let directory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(Log.subsystem)/Transcripts", isDirectory: true)

    private var memory: [String: TranscriptionResult] = [:]
    private static let memoryMax = 4

    func transcript(for url: URL, isVideo: Bool, range: ClosedRange<Double>?, preferredLocale: Locale? = nil) async throws -> TranscriptionResult {
        // When a locale is forced, bypass the cache — locale variants must not overwrite the auto-detected entry.
        if let preferredLocale {
            return isVideo
                ? try await Transcription.transcribeVideoAudio(videoURL: url, preferredLocale: preferredLocale, sourceRange: range)
                : try await Transcription.transcribe(fileURL: url, preferredLocale: preferredLocale, sourceRange: range)
        }
        // Cache full transcripts only; windowed calls filter the cached result for consistency.
        let key = Self.key(for: url)
        let full: TranscriptionResult
        if let key, let cached = cached(key) {
            full = cached
        } else {
            full = isVideo
                ? try await Transcription.transcribeVideoAudio(videoURL: url)
                : try await Transcription.transcribe(fileURL: url)
            // A fallback (e.g. qwen3 unavailable → Apple) stamps a different model than requested.
            // Store under the slot of the engine that ACTUALLY ran, never the requested one —
            // otherwise the fallback would be served from the requested engine's slot forever and
            // shadow a later successful run. Leaving that slot empty keeps the real engine retryable.
            let ran = Self.storageEngine(requested: LocalSpeechEngine.current, resultModel: full.model)
            if let storeKey = Self.key(for: url, variant: .local(engine: ran)) {
                store(full, key: storeKey)
            }
        }
        return range.map { Self.filter(full, to: $0) } ?? full
    }

    /// The engine slot a freshly produced transcript belongs in: the engine whose model stamped the
    /// result. Equals `requested` on success; on a fallback it resolves to the engine that ran.
    static func storageEngine(requested: LocalSpeechEngine, resultModel: String?) -> LocalSpeechEngine {
        guard let resultModel,
              let ran = LocalSpeechEngine.allCases.first(where: { $0.modelId == resultModel }) else { return requested }
        return ran
    }

    // Read-only lookups (search, resync, cache checks) try the requested engine's slot first, then
    // the Apple slot: a fallback-produced transcript lives there, and without the fallback read the
    // asset would be treated as uncached by every read-only consumer. The full `transcript()` path
    // deliberately does NOT read the fallback slot — it re-attempts the requested engine so a
    // transient failure (e.g. model still downloading) heals into the right slot.
    private nonisolated static func readKeys(for url: URL) -> [String] {
        var keys: [String] = []
        if let key = key(for: url) { keys.append(key) }
        if let fallback = key(for: url, variant: .local(engine: .apple)), !keys.contains(fallback) {
            keys.append(fallback)
        }
        return keys
    }

    nonisolated static func hasCachedOnDisk(for url: URL) -> Bool {
        readKeys(for: url).contains { FileManager.default.fileExists(atPath: diskURL($0).path) }
    }

    /// Requested-slot-only probe for SCHEDULING decisions (the background indexer's "needs
    /// transcription?"): a fallback entry must satisfy readers but must NOT suppress the retry
    /// that lets the requested engine heal into its own slot.
    nonisolated static func hasRequestedEngineEntry(for url: URL) -> Bool {
        guard let key = key(for: url) else { return false }
        return FileManager.default.fileExists(atPath: diskURL(key).path)
    }

    /// Disk-only read
    nonisolated static func cachedOnDisk(for url: URL) -> TranscriptionResult? {
        for key in readKeys(for: url) {
            if let data = try? Data(contentsOf: diskURL(key)),
               let result = try? JSONDecoder().decode(TranscriptionResult.self, from: data) {
                return result
            }
        }
        return nil
    }

    static func filter(_ r: TranscriptionResult, to range: ClosedRange<Double>) -> TranscriptionResult {
        let segments = r.segments.filter { $0.end > range.lowerBound && $0.start < range.upperBound }
        let words = r.words.filter { w in
            guard let s = w.start, let e = w.end else { return false }
            return e > range.lowerBound && s < range.upperBound
        }
        return TranscriptionResult(
            text: segments.map(\.text).joined(separator: " "),
            language: r.language,
            words: words,
            segments: segments
        )
    }

    func cachedCloudTranscript(
        for url: URL,
        range: ClosedRange<Double>?,
        language: String?
    ) -> TranscriptionResult? {
        guard let key = Self.key(for: url, variant: .cloud(range: range, language: language)) else { return nil }
        return cached(key)
    }

    func hasCachedCloudTranscript(
        for url: URL,
        range: ClosedRange<Double>?,
        language: String?
    ) -> Bool {
        guard let key = Self.key(for: url, variant: .cloud(range: range, language: language)) else { return false }
        return memory[key] != nil || FileManager.default.fileExists(atPath: Self.diskURL(key).path)
    }

    func storeCloudTranscript(
        _ result: TranscriptionResult,
        for url: URL,
        range: ClosedRange<Double>?,
        language: String?
    ) {
        guard let key = Self.key(for: url, variant: .cloud(range: range, language: language)) else { return }
        store(result, key: key)
    }

    /// Drop in-memory entries so a disk clear isn't shadowed by the memory cache.
    func clearMemory() { memory.removeAll() }

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

    private static func diskURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    private static func key(for url: URL, variant: CacheVariant = .local(engine: LocalSpeechEngine.current)) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let base = "\(url.path)|\(mtime.timeIntervalSince1970)|\(size)"
        let identity = variant.prefix.map { "\($0)|\(base)" } ?? base
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    private enum CacheVariant {
        case local(engine: LocalSpeechEngine)
        case cloud(range: ClosedRange<Double>?, language: String?)

        var prefix: String? {
            switch self {
            case .local(let engine):
                // Engine-tagged so switching engines re-transcribes; Apple stays untagged
                // to keep pre-engine cache entries valid.
                return engine.cacheTag
            case .cloud(let range, let language):
                let lang = language ?? "auto"
                guard let range else { return "cloud|\(lang)|full" }
                return String(format: "cloud|%@|%.3f...%.3f", lang, range.lowerBound, range.upperBound)
            }
        }
    }
}
