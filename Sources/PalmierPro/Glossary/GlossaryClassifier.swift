// GlossaryClassifier — decides whether a caption content edit is a term correction worth promoting.
// Only a single contiguous substitution with clean surroundings promotes; everything else is left
// alone. No confirmation prompts, biased toward promoting (a false positive costs one remove). refs feature/glossary

import Foundation

enum GlossaryClassifier {
    /// A proposed glossary entry derived from an old→new caption edit.
    struct Promotion: Equatable {
        let canonical: String   // the new (corrected) span
        let variant: String     // the old (mis-heard) span
    }

    /// Classify an old→new caption edit. Returns a promotion only for a single contiguous
    /// substitution whose replaced span is a plausible term (not filler, common vocab, punctuation,
    /// or an unsafe-length variant). Pure deletions, insertions, scattered edits, and
    /// punctuation/casing/whitespace-only changes return nil.
    static func classify(old: String, new: String) -> Promotion? {
        let oldTrimmed = old.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTrimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard oldTrimmed != newTrimmed else { return nil }
        // Whole-edit punctuation/casing/whitespace-only change → nothing to correct.
        if normalize(oldTrimmed) == normalize(newTrimmed) { return nil }

        let isCJK = GlossaryText.isCJKPhrase(oldTrimmed) || GlossaryText.isCJKPhrase(newTrimmed)
        let oldTokens = tokenize(oldTrimmed, isCJK: isCJK)
        let newTokens = tokenize(newTrimmed, isCJK: isCJK)

        let regions = diffRegions(oldTokens, newTokens)
        guard regions.count == 1 else { return nil }  // scattered or multi-region → not a term fix
        let region = regions[0]

        let oldSpanTokens = Array(oldTokens[region.oldRange])
        let newSpanTokens = Array(newTokens[region.newRange])
        // Substitution only: both sides non-empty (rules out pure delete / pure insert).
        guard !oldSpanTokens.isEmpty, !newSpanTokens.isEmpty else { return nil }

        let variant = join(oldSpanTokens, isCJK: isCJK)
        let canonical = join(newSpanTokens, isCJK: isCJK)
        guard !variant.isEmpty, !canonical.isEmpty else { return nil }

        // Guards. Phonetic distance is deliberately NOT one of them.
        if normalize(variant) == normalize(canonical) { return nil }          // punctuation/casing-only span
        if GlossaryCommonWords.isAllFiller(oldSpanTokens) { return nil }        // filler cleanup
        if GlossaryCommonWords.isAllFiller(newSpanTokens) { return nil }
        if GlossaryCommonWords.isCommonVocabulary(canonical) { return nil }     // rephrase, not a term
        if GlossaryValidation.tooShortReason(variant) != nil { return nil }     // unsafe to find/replace

        return Promotion(canonical: canonical, variant: variant)
    }

    // MARK: - Tokenization

    private static func tokenize(_ s: String, isCJK: Bool) -> [String] {
        if isCJK {
            return s.filter { !$0.isWhitespace }.map(String.init)  // character-level, whitespace dropped
        }
        return s.split(whereSeparator: { $0.isWhitespace }).map(String.init)  // word-level
    }

    private static func join(_ tokens: [String], isCJK: Bool) -> String {
        tokens.joined(separator: isCJK ? "" : " ")
    }

    /// Casing + edge-punctuation-insensitive normalization for equality checks.
    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: .whitespaces).joined()
            .trimmingCharacters(in: .punctuationCharacters)
            .filter { !$0.isPunctuation }
    }

    // MARK: - Diff

    private struct Region {
        let oldRange: Range<Int>
        let newRange: Range<Int>
    }

    /// Groups the token-level edit script into contiguous changed regions using an LCS alignment.
    /// A region spans consecutive deletes/inserts between two matched anchors.
    private static func diffRegions(_ a: [String], _ b: [String]) -> [Region] {
        let lcs = lcsMatches(a, b)  // aligned matched index pairs, ascending
        var regions: [Region] = []
        var ai = 0, bi = 0
        func pushRegion(oldEnd: Int, newEnd: Int) {
            if ai < oldEnd || bi < newEnd {
                regions.append(Region(oldRange: ai..<oldEnd, newRange: bi..<newEnd))
            }
        }
        for (ma, mb) in lcs {
            pushRegion(oldEnd: ma, newEnd: mb)
            ai = ma + 1
            bi = mb + 1
        }
        pushRegion(oldEnd: a.count, newEnd: b.count)
        return regions
    }

    /// Longest common subsequence as matched (indexInA, indexInB) pairs.
    private static func lcsMatches(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var matches: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                matches.append((i, j)); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return matches
    }
}
