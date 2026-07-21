// GlossaryClassifier — decides whether a caption content edit is a term correction worth promoting.
// Only a single contiguous substitution with clean surroundings promotes; everything else is left
// alone. No confirmation prompts, biased toward promoting (a false positive costs one remove). refs feature/glossary

import Foundation
import NaturalLanguage

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

        // Guards apply to the MINIMAL span. Phonetic distance is deliberately NOT one of them.
        if normalize(variant) == normalize(canonical) { return nil }          // punctuation/casing-only span
        if GlossaryCommonWords.isAllFiller(oldSpanTokens) { return nil }        // filler cleanup
        if GlossaryCommonWords.isAllFiller(newSpanTokens) { return nil }
        if GlossaryCommonWords.isCommonVocabulary(canonical) { return nil }     // rephrase, not a term

        // Length safety: a variant below the find/replace threshold (a single CJK char like 开→拍)
        // would corrupt longer words. Dropping it makes the user re-fix the term every episode, so
        // instead widen the span into the shared neighbouring context until the variant clears the
        // threshold (开→拍 inside 开照片→拍照片 becomes 开照片→拍照片). CJK only; Latin is unchanged.
        if GlossaryValidation.tooShortReason(variant) != nil {
            guard isCJK, let widened = widen(old: oldTrimmed, new: newTrimmed) else { return nil }
            return widened
        }

        return Promotion(canonical: canonical, variant: variant)
    }

    // MARK: - Span widening

    /// Widen a sub-threshold minimal substitution into the shared neighbouring context until the
    /// variant is safe to find/replace. Extends by whole NLTokenizer word groups (so the change grows
    /// to the enclosing word), suffix first then prefix, bounded by the caption. The result is always
    /// a contiguous substring of `old`/`new`. Returns nil when no context can clear the threshold.
    private static func widen(old: String, new: String) -> Promotion? {
        let o = Array(old), n = Array(new)
        var p = 0
        while p < o.count && p < n.count && o[p] == n[p] { p += 1 }
        var s = 0
        while s < o.count - p && s < n.count - p && o[o.count - 1 - s] == n[n.count - 1 - s] { s += 1 }
        let oldSpan = Array(o[p..<o.count - s])
        let newSpan = Array(n[p..<n.count - s])
        guard !oldSpan.isEmpty, !newSpan.isEmpty else { return nil }

        let pre = Array(o[0..<p])
        let suf = Array(o[(o.count - s)...])
        let sufEnds = wordBoundaries(suf).ends          // consume from the start
        let preStarts = wordBoundaries(pre).starts      // consume from the end
        var si = 0, pi = preStarts.count - 1
        var leadLen = 0, trailLen = 0
        func variant() -> String { String(Array(pre.suffix(leadLen)) + oldSpan + Array(suf.prefix(trailLen))) }
        func canonical() -> String { String(Array(pre.suffix(leadLen)) + newSpan + Array(suf.prefix(trailLen))) }
        while GlossaryValidation.tooShortReason(variant()) != nil {
            if si < sufEnds.count {
                trailLen = sufEnds[si]; si += 1
            } else if pi >= 0 {
                leadLen = pre.count - preStarts[pi]; pi -= 1
            } else {
                return nil  // context exhausted, still unsafe
            }
        }
        let v = variant(), c = canonical()
        guard normalize(v) != normalize(c) else { return nil }
        // Re-apply the rephrase/filler guards to the WIDENED spans, not just the minimal char:
        // widening a sub-threshold single-char edit can produce an all-common-vocabulary span
        // (在→再 widening to 在来→再来) that would silently corrupt unrelated text (现在来 → 现再来).
        // Only a span carrying a non-common, non-filler character earns promotion.
        if GlossaryCommonWords.isCommonVocabulary(v) || GlossaryCommonWords.isCommonVocabulary(c) { return nil }
        if GlossaryCommonWords.isAllFiller(v.map(String.init)) || GlossaryCommonWords.isAllFiller(c.map(String.init)) { return nil }
        return Promotion(canonical: c, variant: v)
    }

    /// Character offsets of NLTokenizer word-group boundaries within `chars` (offsets index into
    /// `chars`). `starts`/`ends` skip inter-token whitespace, so slicing to a boundary lands on a word.
    private static func wordBoundaries(_ chars: [Character]) -> (starts: [Int], ends: [Int]) {
        guard !chars.isEmpty else { return ([], []) }
        let s = String(chars)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = s
        var starts: [Int] = [], ends: [Int] = []
        tokenizer.enumerateTokens(in: s.startIndex..<s.endIndex) { range, _ in
            starts.append(s.distance(from: s.startIndex, to: range.lowerBound))
            ends.append(s.distance(from: s.startIndex, to: range.upperBound))
            return true
        }
        return (starts, ends)
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
