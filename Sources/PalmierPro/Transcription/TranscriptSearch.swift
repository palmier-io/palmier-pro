import Foundation

/// Exact keyword search over cached transcripts
enum TranscriptSearch {
    struct Hit: Equatable {
        let assetID: String
        let start: Double
        let end: Double
        let text: String
        /// From a prior engine tag (e.g. qw6 after the qw7 bump): findable but pre-punctuation.
        let stale: Bool

        init(assetID: String, start: Double, end: Double, text: String, stale: Bool = false) {
            self.assetID = assetID
            self.start = start
            self.end = end
            self.text = text
            self.stale = stale
        }
    }

    /// Dual-layer search: a query hits if it matches the RAW segment text OR the glossary-CORRECTED
    /// text, so both the mis-heard spelling and the canonical stay findable. Corrected/canonical hits
    /// rank above raw-only hits. Passing no corrector (or an empty one) searches raw text only.
    /// Reads tolerate a tag bump: an asset with no current-tag transcript falls back to a prior tag's
    /// entry, and its hits are flagged `stale` (see cachedOnDiskAllowingStale).
    static func search(
        query: String,
        assets: [(id: String, url: URL)],
        limit: Int = 20,
        corrector: GlossaryCorrector? = nil,
        engine: LocalSpeechEngine = .current
    ) -> [Hit] {
        let loaded = assets.compactMap { asset in
            TranscriptCache.cachedOnDiskAllowingStale(for: asset.url, engine: engine)
                .map { (id: asset.id, transcript: $0.result, stale: $0.stale) }
        }
        let staleIDs = Set(loaded.filter(\.stale).map(\.id))
        let hits = rank(
            query: query,
            transcripts: loaded.map { (assetID: $0.id, transcript: $0.transcript) },
            limit: limit,
            corrector: corrector
        )
        guard !staleIDs.isEmpty else { return hits }
        return hits.map { hit in
            Hit(assetID: hit.assetID, start: hit.start, end: hit.end, text: hit.text, stale: staleIDs.contains(hit.assetID))
        }
    }

    /// The disk-independent ranking core: a query hits if it matches the RAW segment text OR the
    /// glossary-CORRECTED text, so both the mis-heard spelling and the canonical stay findable.
    /// Corrected/canonical hits rank above raw-only hits.
    static func rank(
        query: String,
        transcripts: [(assetID: String, transcript: TranscriptionResult)],
        limit: Int = 20,
        corrector: GlossaryCorrector? = nil
    ) -> [Hit] {
        let terms = terms(in: query)
        guard !terms.isEmpty else { return [] }

        var corrected: [Hit] = []   // matched the canonical/corrected layer — ranked first
        var rawOnly: [Hit] = []     // matched only the raw transcript
        for (assetID, transcript) in transcripts {
            for segment in transcript.segments {
                let correctedText = corrector.map { $0.isEmpty ? segment.text : $0.correct(segment.text) } ?? segment.text
                let hitsCorrected = correctedText != segment.text && matches(correctedText, terms: terms)
                let hitsRaw = matches(segment.text, terms: terms)
                if hitsCorrected {
                    corrected.append(Hit(assetID: assetID, start: segment.start, end: segment.end, text: correctedText))
                } else if hitsRaw {
                    rawOnly.append(Hit(assetID: assetID, start: segment.start, end: segment.end, text: segment.text))
                }
            }
        }
        return Array((corrected + rawOnly).prefix(limit))
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
