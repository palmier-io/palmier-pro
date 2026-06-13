import Foundation

enum SpokenSearch {
    struct Hit: Equatable {
        let assetID: String
        let start: Double
        let end: Double
        let text: String
    }

    private static let semanticFloor: Float = 0.55
    private static let maxSemantic = 3

    static func search(
        query: String, assets: [(id: String, url: URL)], limit: Int = 20
    ) async -> [Hit] {
        let keyword = Keyword.search(query: query, assets: assets, limit: limit)
        guard keyword.count < limit, SpokenModel.anyAvailable else { return keyword }

        var byFamily: [SpokenModel: [(String, EmbeddingStore.AssetIndex)]] = [:]
        var transcripts: [String: TranscriptionResult] = [:]
        for (id, url) in assets {
            guard let key = EmbeddingStore.key(for: url),
                  let index = try? EmbeddingStore.load(key: SpokenIndexer.spokenKey(key)),
                  index.header.count > 0,
                  let family = SpokenModel(rawValue: index.header.model) else { continue }
            byFamily[family, default: []].append((id, index))
            transcripts[id] = TranscriptCache.cachedOnDisk(for: url)
        }
        guard !byFamily.isEmpty else { return keyword }

        var semantic: [VisualSearch.Hit] = []
        for (family, indexes) in byFamily {
            guard let queryVector = await SpokenEmbedder.shared.vector(for: query, family: family) else { continue }
            semantic += rankCentered(query: queryVector, indexes: indexes)
        }
        semantic = semantic.filter { $0.score >= semanticFloor }.sorted { $0.score > $1.score }
        semantic = Array(semantic.prefix(maxSemantic))
        return merge(keyword: keyword, semantic: semantic, transcripts: transcripts, limit: limit)
    }

    /// Ranks windows by mean-centered cosine: subtract the candidate set's mean vector from
    /// the query and each window (removing the anisotropic common direction) before scoring.
    private static func rankCentered(
        query: [Float], indexes: [(String, EmbeddingStore.AssetIndex)]
    ) -> [VisualSearch.Hit] {
        guard let dim = indexes.first?.1.header.dim else { return [] }
        var mean = [Float](repeating: 0, count: dim)
        var count = 0
        for (_, idx) in indexes where idx.header.dim == dim {
            for i in 0..<idx.header.count {
                let base = i * dim
                for d in 0..<dim { mean[d] += idx.vectors[base + d] }
                count += 1
            }
        }
        guard count > 0 else { return [] }
        for d in 0..<dim { mean[d] /= Float(count) }

        let q = centered(query, mean: mean)
        var hits: [VisualSearch.Hit] = []
        for (assetID, idx) in indexes where idx.header.dim == dim {
            for i in 0..<idx.header.count {
                let base = i * dim
                let w = centered(Array(idx.vectors[base..<base + dim]), mean: mean)
                var score: Float = 0
                for d in 0..<dim { score += q[d] * w[d] }
                let row = idx.rows[i]
                hits.append(.init(assetID: assetID, time: row.time,
                                  shotStart: row.shotStart, shotEnd: row.shotEnd, score: score))
            }
        }
        return hits
    }

    /// v - mean, L2-normalized.
    private static func centered(_ v: [Float], mean: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: v.count)
        var norm: Float = 0
        for i in 0..<v.count { let c = v[i] - mean[i]; out[i] = c; norm += c * c }
        norm = norm.squareRoot()
        guard norm > 0 else { return out }
        for i in 0..<out.count { out[i] /= norm }
        return out
    }

    /// Appends semantic hits below the keyword tier, skipping segments keyword already found.
    static func merge(
        keyword: [Hit],
        semantic: [VisualSearch.Hit],
        transcripts: [String: TranscriptionResult],
        limit: Int
    ) -> [Hit] {
        var seen = Set(keyword.map { "\($0.assetID)@\($0.start)" })
        var hits = keyword
        for s in semantic {
            guard hits.count < limit else { break }
            let dedupeKey = "\(s.assetID)@\(s.shotStart)"
            guard !seen.contains(dedupeKey),
                  let text = windowText(transcripts[s.assetID], start: s.shotStart, end: s.shotEnd)
            else { continue }
            seen.insert(dedupeKey)
            hits.append(Hit(assetID: s.assetID, start: s.shotStart, end: s.shotEnd, text: text))
        }
        return hits
    }

    /// Reconstructs a window's text by joining the transcript segments it spans.
    static func windowText(_ transcript: TranscriptionResult?, start: Double, end: Double) -> String? {
        guard let transcript else { return nil }
        let parts = transcript.segments
            .filter { $0.end > start && $0.start < end }
            .sorted { $0.start < $1.start }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Exact-keyword tier: cached transcripts, all query words present in any order.
    enum Keyword {
        /// Query split into words, edge punctuation stripped (so "budget," → "budget").
        static func terms(in query: String) -> [String] {
            query.split(whereSeparator: \.isWhitespace)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { !$0.isEmpty }
        }

        static func matches(_ text: String, terms: [String]) -> Bool {
            terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }

        static func search(query: String, assets: [(id: String, url: URL)], limit: Int = 20) -> [Hit] {
            let terms = terms(in: query)
            guard !terms.isEmpty else { return [] }

            var hits: [Hit] = []
            for asset in assets {
                guard let transcript = TranscriptCache.cachedOnDisk(for: asset.url) else { continue }
                for segment in transcript.segments where matches(segment.text, terms: terms) {
                    hits.append(Hit(assetID: asset.id, start: segment.start, end: segment.end, text: segment.text))
                    if hits.count >= limit { return hits }
                }
            }
            return hits
        }
    }
}
