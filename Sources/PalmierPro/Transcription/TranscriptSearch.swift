import Foundation

/// Exact keyword search over cached transcripts
enum TranscriptSearch {
    struct Hit: Equatable {
        let assetID: String
        let start: Double
        let end: Double
        let text: String
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

    /// Query split into words, edge punctuation stripped (so "budget," → "budget").
    static func terms(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    static func matches(_ text: String, terms: [String]) -> Bool {
        terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
