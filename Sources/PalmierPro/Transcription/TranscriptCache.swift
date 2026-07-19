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

    /// `cacheTag` opts this call into a bias-salted key (e.g. a decoder-bias fingerprint) so a caller
    /// that wants a fresh biased decode gets one. The hot path passes nil and reads/writes the UNSALTED
    /// key: read-time glossary materialisation already applies corrections regardless of what decoded,
    /// so salting every glossary edit here would re-transcribe the whole file for marginal decode gain.
    /// `cachedOnDisk` reads unsalted→salted so this fresh write wins over any stale pre-A3 salted entry,
    /// keeping the salted key only as a fallback for legacy salted-only entries. §4
    /// `engine` is the caller's resolved on-device engine (a per-project override, else the app-global
    /// default). It selects the engine that runs AND the cache slot the entry lives in, so switching
    /// engines/variants re-transcribes into a distinct key with no cross-variant collision. nil = global.
    func transcript(for url: URL, isVideo: Bool, range: ClosedRange<Double>?, preferredLocale: Locale? = nil, cacheTag: String? = nil, engine: LocalSpeechEngine? = nil) async throws -> TranscriptionResult {
        let engine = engine ?? .current
        // When a locale is forced, bypass the cache — locale variants must not overwrite the auto-detected entry.
        if let preferredLocale {
            return isVideo
                ? try await Transcription.transcribeVideoAudio(videoURL: url, preferredLocale: preferredLocale, sourceRange: range, engine: engine)
                : try await Transcription.transcribe(fileURL: url, preferredLocale: preferredLocale, sourceRange: range, engine: engine)
        }
        // Cache full transcripts only; windowed calls filter the cached result for consistency.
        let key = Self.key(for: url, variant: .local(engine: engine), cacheTag: cacheTag)
        let full: TranscriptionResult
        if let key, let cached = cached(key) {
            full = cached
        } else {
            full = isVideo
                ? try await Transcription.transcribeVideoAudio(videoURL: url, engine: engine)
                : try await Transcription.transcribe(fileURL: url, engine: engine)
            // A fallback (e.g. qwen3 unavailable → Apple) stamps a different model than requested. Store
            // it under the slot of the engine that ACTUALLY ran, never the requested one — otherwise the
            // requested slot would serve the fallback forever and shadow a later successful run. Leaving
            // the requested slot empty lets the next call re-attempt the real engine.
            let ranEngine = Self.storageEngine(requested: engine, resultModel: full.model)
            if let storeKey = Self.key(for: url, variant: .local(engine: ranEngine), cacheTag: cacheTag) {
                store(full, key: storeKey)
            }
        }
        return range.map { Self.filter(full, to: $0) } ?? full
    }

    /// The engine slot a freshly produced transcript belongs in: the engine whose model actually stamped
    /// the result. Equals `requested` on success; on a fallback it resolves to the engine that ran (so the
    /// requested slot stays empty and retryable). An untagged/unknown model defaults to `requested`.
    static func storageEngine(requested: LocalSpeechEngine, resultModel: String?) -> LocalSpeechEngine {
        guard let resultModel,
              let ran = LocalSpeechEngine.allCases.first(where: { $0.modelId == resultModel }) else { return requested }
        return ran
    }

    // Read-only lookups try the UNSALTED local key first — transcript() writes unsalted, so a fresh
    // unsalted entry must win over a stale pre-A3 salted one for the same file (else resync/search would
    // diverge from generation's read). The bias-salted key is a later fallback so legacy salted-only
    // entries (written under the old always-salt code) stay readable, and finally the provider-neutral
    // alias that full-file cloud transcripts write under — cloud entries live in .cloud-variant keys the
    // local scheme never reaches, so without the alias cloud projects would never resync.
    private nonisolated static func readKeys(for url: URL, engine: LocalSpeechEngine) -> [String] {
        var tags: [String?] = [nil]
        if let fingerprint = TranscriptionBias.fingerprint { tags.append(fingerprint) }
        return tags.compactMap { key(for: url, variant: .local(engine: engine), cacheTag: $0) }
            + [key(for: url, variant: .readAlias)].compactMap { $0 }
    }

    nonisolated static func hasCachedOnDisk(for url: URL, engine: LocalSpeechEngine? = nil) -> Bool {
        readKeys(for: url, engine: engine ?? .current).contains { FileManager.default.fileExists(atPath: diskURL($0).path) }
    }

    /// Disk-only read. `engine` selects the local cache slot to read (a per-project override, else global),
    /// keeping cache-only readers (resync, search, glossary apply) symmetric with what `transcript` wrote.
    nonisolated static func cachedOnDisk(for url: URL, engine: LocalSpeechEngine? = nil) -> TranscriptionResult? {
        for key in readKeys(for: url, engine: engine ?? .current) {
            if let data = try? Data(contentsOf: diskURL(key)),
               let result = try? JSONDecoder().decode(TranscriptionResult.self, from: data) {
                return result
            }
        }
        return nil
    }

    /// Disk-only read for read-only consumers that prefer stale text over nothing (spoken search).
    /// Returns the current-tag entry when present (`stale: false`); otherwise falls back to this
    /// engine's PRIOR cache tags (`stale: true`) so a tag bump doesn't blank search — the qw6 entries
    /// the bump orphaned stay findable. `transcript()` still regenerates under the current tag on a
    /// full read, so this never poisons the current slot. Resync deliberately does NOT use this — it
    /// needs the current tag's word stream and skips uncached refs instead.
    nonisolated static func cachedOnDiskAllowingStale(
        for url: URL, engine: LocalSpeechEngine? = nil
    ) -> (result: TranscriptionResult, stale: Bool)? {
        let engine = engine ?? .current
        if let fresh = cachedOnDisk(for: url, engine: engine) { return (fresh, false) }
        for tag in engine.priorCacheTags {
            guard let key = key(for: url, variant: .localTag(tag)),
                  let data = try? Data(contentsOf: diskURL(key)),
                  let result = try? JSONDecoder().decode(TranscriptionResult.self, from: data) else { continue }
            return (result, true)
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
            segments: segments,
            model: r.model
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
        // A full-file cloud transcript is the one resync/search read via cachedOnDisk; publish it under
        // the provider-neutral alias so those readers find it without knowing the cloud language/range.
        if range == nil, let alias = Self.key(for: url, variant: .readAlias) {
            store(result, key: alias)
        }
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

    static func diskURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    static func key(for url: URL, variant: CacheVariant = .local(engine: .current), cacheTag: String? = nil) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        var base = "\(url.path)|\(mtime.timeIntervalSince1970)|\(size)"
        if let cacheTag { base += "|bias:\(cacheTag)" }
        let identity = variant.prefix.map { "\($0)|\(base)" } ?? base
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    enum CacheVariant {
        case local(engine: LocalSpeechEngine)
        case localTag(String?)  // explicit engine tag; used to reach a prior version's slot for stale reads
        case cloud(range: ClosedRange<Double>?, language: String?)
        case readAlias  // provider-neutral "latest full transcript" pointer; the fallback cachedOnDisk reads

        var prefix: String? {
            switch self {
            case .local(let engine):
                // Engine-tagged so switching engines/variants re-transcribes; Apple stays untagged
                // to keep pre-engine cache entries valid.
                return engine.cacheTag
            case .localTag(let tag):
                return tag
            case .cloud(let range, let language):
                let lang = language ?? "auto"
                guard let range else { return "cloud|\(lang)|full" }
                return String(format: "cloud|%@|%.3f...%.3f", lang, range.lowerBound, range.upperBound)
            case .readAlias:
                return "latest"
            }
        }
    }
}
