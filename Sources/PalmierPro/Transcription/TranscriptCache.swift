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
    /// `cachedOnDisk` still falls back salted→unsalted, so pre-existing salted entries stay readable. §4
    func transcript(for url: URL, isVideo: Bool, range: ClosedRange<Double>?, preferredLocale: Locale? = nil, cacheTag: String? = nil) async throws -> TranscriptionResult {
        // When a locale is forced, bypass the cache — locale variants must not overwrite the auto-detected entry.
        if let preferredLocale {
            return isVideo
                ? try await Transcription.transcribeVideoAudio(videoURL: url, preferredLocale: preferredLocale, sourceRange: range)
                : try await Transcription.transcribe(fileURL: url, preferredLocale: preferredLocale, sourceRange: range)
        }
        // Cache full transcripts only; windowed calls filter the cached result for consistency.
        let key = Self.key(for: url, cacheTag: cacheTag)
        let full: TranscriptionResult
        if let key, let cached = cached(key) {
            full = cached
        } else {
            full = isVideo
                ? try await Transcription.transcribeVideoAudio(videoURL: url)
                : try await Transcription.transcribe(fileURL: url)
            if let key { store(full, key: key) }
        }
        return range.map { Self.filter(full, to: $0) } ?? full
    }

    // Read-only lookups prefer the bias-salted local entry, fall back to the unsalted one (so
    // pre-glossary transcripts stay searchable/resyncable), and finally the provider-neutral alias
    // that full-file cloud transcripts write under — cloud entries live in .cloud-variant keys the
    // local scheme never reaches, so without the alias cloud projects would never resync.
    private nonisolated static func readKeys(for url: URL) -> [String] {
        let tags: [String?] = TranscriptionBias.fingerprint.map { [$0, nil] } ?? [nil]
        return (tags.compactMap { key(for: url, cacheTag: $0) } + [key(for: url, variant: .readAlias)].compactMap { $0 })
    }

    nonisolated static func hasCachedOnDisk(for url: URL) -> Bool {
        readKeys(for: url).contains { FileManager.default.fileExists(atPath: diskURL($0).path) }
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

    private static func diskURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    static func key(for url: URL, variant: CacheVariant = .local, cacheTag: String? = nil) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        var base = "\(url.path)|\(mtime.timeIntervalSince1970)|\(size)"
        if let cacheTag { base += "|bias:\(cacheTag)" }
        let identity = variant.prefix.map { "\($0)|\(base)" } ?? base
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    enum CacheVariant {
        case local
        case cloud(range: ClosedRange<Double>?, language: String?)
        case readAlias  // provider-neutral "latest full transcript" pointer; the fallback cachedOnDisk reads

        var prefix: String? {
            switch self {
            case .local:
                // Engine-tagged so switching engines re-transcribes; Apple stays untagged
                // to keep pre-engine cache entries valid.
                return LocalSpeechEngine.current.cacheTag
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
