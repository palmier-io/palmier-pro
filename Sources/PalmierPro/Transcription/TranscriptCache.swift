import CryptoKit
import Foundation

extension Notification.Name {
    /// Posted with the media `URL` after a transcript is written to the cache.
    static let transcriptCacheDidStore = Notification.Name("io.palmier.pro.transcriptCacheDidStore")
}

/// Disk + memory cache for local and cloud transcripts, keyed by file identity so edits invalidate naturally.
actor TranscriptCache {
    static let shared = TranscriptCache()
    static let directory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(Log.subsystem)/Transcripts", isDirectory: true)

    private var memory: [String: TranscriptionResult] = [:]
    private var legacyLookupMisses: Set<String> = []
    private static let memoryMax = 4

    func transcript(for url: URL, isVideo: Bool, range: ClosedRange<Double>?, preferredLocale: Locale? = nil) async throws -> TranscriptionResult {
        try Task.checkCancellation()
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
            try Task.checkCancellation()
            if let key {
                store(full, key: key)
                Self.notifyDidStore(url)
            }
        }
        try Task.checkCancellation()
        return range.map { Self.filter(full, to: $0) } ?? full
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

    func cachedTranscript(for url: URL) -> TranscriptionResult? {
        guard let identity = Self.sourceIdentity(for: url) else { return nil }
        let sourceKey = Self.key(for: identity)
        if let transcript = cached(sourceKey) { return transcript }
        if let transcript = cached(Self.key(for: identity, variant: .cloudLookup)) {
            return transcript
        }
        // Pre-lookup cloud|auto|full entries written before cloudLookup dual-write.
        if let transcript = cached(Self.key(for: identity, variant: .cloud(range: nil, language: nil))) {
            return transcript
        }
        if legacyLookupMisses.insert(sourceKey).inserted {
            let cachedFiles = Set(
                (try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)) ?? []
            )
            for language in Locale.LanguageCode.isoLanguageCodes.map(\.identifier) {
                let key = Self.key(for: identity, variant: .cloud(range: nil, language: language))
                guard cachedFiles.contains("\(key).json"),
                      let transcript = cached(key) else { continue }
                store(transcript, key: Self.key(for: identity, variant: .cloudLookup))
                return transcript
            }
        }
        return cached(Self.key(for: identity, variant: .cloudRangeLookup))
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
        // Keep full and ranged fallbacks separate so a partial result cannot replace a full one.
        let lookupVariant: CacheVariant = range == nil ? .cloudLookup : .cloudRangeLookup
        if let lookupKey = Self.key(for: url, variant: lookupVariant) {
            store(result, key: lookupKey)
        }
        Self.notifyDidStore(url)
    }

    /// Drop in-memory entries so a disk clear isn't shadowed by the memory cache.
    func clearMemory() {
        memory.removeAll()
        legacyLookupMisses.removeAll()
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

    private nonisolated static func notifyDidStore(_ url: URL) {
        NotificationCenter.default.post(name: .transcriptCacheDidStore, object: url)
    }

    private static func diskURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    private static func key(for url: URL, variant: CacheVariant = .local) -> String? {
        guard let identity = sourceIdentity(for: url) else { return nil }
        return key(for: identity, variant: variant)
    }

    private static func sourceIdentity(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return "\(url.path)|\(mtime.timeIntervalSince1970)|\(size)"
    }

    private static func key(for identity: String, variant: CacheVariant = .local) -> String {
        let seed = variant.prefix.map { "\($0)|\(identity)" } ?? identity
        return SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    private enum CacheVariant {
        case local
        case cloud(range: ClosedRange<Double>?, language: String?)
        /// Full cloud transcript lookup that ignores the language used when storing.
        case cloudLookup
        case cloudRangeLookup

        var prefix: String? {
            switch self {
            case .local:
                return nil
            case .cloudLookup:
                return "cloud|any|full"
            case .cloudRangeLookup:
                return "cloud|any|range"
            case .cloud(let range, let language):
                let lang = language ?? "auto"
                guard let range else { return "cloud|\(lang)|full" }
                return String(format: "cloud|%@|%.3f...%.3f", lang, range.lowerBound, range.upperBound)
            }
        }
    }
}
