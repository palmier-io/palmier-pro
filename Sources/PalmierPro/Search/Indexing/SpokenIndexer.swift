import Foundation

/// Embeds windowed transcript text for semantic spoken search; one row per window,
/// stored beside the visual index. Model family comes from the transcript language.
enum SpokenIndexer {
    /// Bumped if pooling/windowing changes (invalidates every family at once).
    static let poolingVersion = 3
    /// Floor for windows that stay lone interjections after merging; keyword search still covers those.
    static let minSemanticWords = 3
    /// Written for transcripts no family covers, so the asset settles instead of re-queueing.
    static let unsupportedModelID = "nlce-none"

    static func spokenKey(_ fileKey: String) -> String { fileKey + "-spoken" }

    /// False until a transcript exists — transcription creates the work, not the file alone.
    static func needsIndex(url: URL) -> Bool {
        guard SpokenModel.anyAvailable, let stamp = TranscriptCache.diskStamp(for: url),
              let key = EmbeddingStore.key(for: url) else { return false }
        guard let header = EmbeddingStore.header(key: spokenKey(key)) else { return true }
        return !isCurrent(header, stamp: stamp)
    }

    private static func isCurrent(_ h: EmbeddingStore.Header, stamp: String) -> Bool {
        guard h.samplerVersion == poolingVersion, h.sourceStamp == stamp else { return false }
        if h.model == unsupportedModelID { return true }
        guard let family = SpokenModel(rawValue: h.model) else { return false }
        return h.modelVersion == family.revision
    }

    static func index(url: URL) async throws {
        guard SpokenModel.anyAvailable, needsIndex(url: url),
              let key = EmbeddingStore.key(for: url),
              let stamp = TranscriptCache.diskStamp(for: url),
              let transcript = TranscriptCache.cachedOnDisk(for: url) else { return }

        guard let family = SpokenModel.family(forBCP47: transcript.language) else {
            try save(modelID: unsupportedModelID, version: 0, dim: 1, rows: [], vectors: [], stamp: stamp, key: key)
            return
        }
        // Model assets not ready: skip without writing so a later sweep retries.
        guard let dim = await SpokenEmbedder.shared.dimension(family) else { return }

        var rows: [EmbeddingStore.Row] = []
        var vectors: [Float] = []
        for window in SpokenWindowBuilder.windows(from: transcript) {
            try Task.checkCancellation()
            guard window.text.split(whereSeparator: \.isWhitespace).count >= Self.minSemanticWords else { continue }
            guard let v = await SpokenEmbedder.shared.vector(for: window.text, family: family),
                  v.count == dim else { continue }
            vectors += v
            rows.append(EmbeddingStore.Row(time: window.start, shotStart: window.start, shotEnd: window.end))
        }
        try save(modelID: family.rawValue, version: family.revision, dim: dim, rows: rows, vectors: vectors, stamp: stamp, key: key)
    }

    private static func save(
        modelID: String, version: Int, dim: Int,
        rows: [EmbeddingStore.Row], vectors: [Float], stamp: String, key: String
    ) throws {
        let header = EmbeddingStore.Header(
            model: modelID, modelVersion: version,
            samplerVersion: poolingVersion, dim: dim, count: rows.count, sourceStamp: stamp
        )
        try EmbeddingStore.save(header: header, rows: rows, vectors: vectors, key: spokenKey(key))
    }
}

/// Groups transcript segments into ~6 s (max 12 s) windows for richer embeddings.
/// Merge-only: a window spans whole segments, so its text reconstructs at query time.
enum SpokenWindowBuilder {
    static let targetDuration: Double = 6
    static let maxDuration: Double = 12
    static let mergeGap: Double = 1

    struct Window: Equatable, Sendable {
        var text: String
        var start: Double
        var end: Double
    }

    static func windows(from result: TranscriptionResult) -> [Window] {
        var out: [Window] = []
        for segment in result.segments {
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Punctuation-only utterances ("...", ".") embed to junk vectors.
            guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            if var last = out.last,
               last.end - last.start < targetDuration,
               segment.start - last.end <= mergeGap,
               segment.end - last.start <= maxDuration {
                last.text += " " + trimmed
                last.end = segment.end
                out[out.count - 1] = last
            } else {
                out.append(Window(text: trimmed, start: segment.start, end: segment.end))
            }
        }
        return out
    }
}
