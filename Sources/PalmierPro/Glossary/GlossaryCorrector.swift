// GlossaryCorrector — variant→canonical find/replace over transcript text, longest-match-first
// with token/word boundaries so a short variant never corrupts a longer known term. refs feature/glossary

import Foundation

/// Compiled, read-only replacement engine built from a glossary's auto-apply terms.
/// Text-only: it substitutes spellings and never shifts timings.
struct GlossaryCorrector: Sendable {
    /// A known string the scanner can match: a variant (replaced with `canonical`) or a
    /// canonical/protected term (matched but left unchanged, so it shields shorter variants).
    private struct Known: Sendable {
        let chars: [Character]
        let canonical: String
        let isLatin: Bool
        let replaces: Bool   // false for protected canonicals
    }

    private let known: [Known]              // sorted longest-first for greedy matching
    private let wordSpanLookup: [String: String]  // normalized whole-phrase → canonical
    private let maxSpanChars: Int
    let isEmpty: Bool

    /// Build from the auto-apply terms of a merged glossary. `terms` should already be filtered
    /// to auto-apply confidences by the caller.
    init(terms: [GlossaryTerm]) {
        var known: [Known] = []
        var wordSpan: [String: String] = [:]
        var maxSpan = 0
        var seenCanonicals = Set<String>()

        for term in terms {
            let canonical = term.canonical
            if seenCanonicals.insert(canonical).inserted {
                // Protect the canonical itself so a variant can't match inside it.
                known.append(Known(
                    chars: Array(canonical),
                    canonical: canonical,
                    isLatin: !GlossaryText.isCJKPhrase(canonical),
                    replaces: false
                ))
            }
            for variant in term.variants
            where variant != canonical && !variant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let isLatin = !GlossaryText.isCJKPhrase(variant)
                known.append(Known(chars: Array(variant), canonical: canonical, isLatin: isLatin, replaces: true))
                // Two terms may share a variant; keep the lexicographically-smaller canonical so this
                // matches the winner `match` returns from the sorted `known` list.
                let key = Self.normalize(variant, isLatin: isLatin)
                if let existing = wordSpan[key] { wordSpan[key] = min(existing, canonical) } else { wordSpan[key] = canonical }
                maxSpan = max(maxSpan, variant.count)
            }
        }
        // Longest first; protected canonicals ahead of equal-length variants so nesting wins; then a
        // lexicographic canonical tie-break so two terms sharing a variant resolve deterministically.
        known.sort { a, b in
            if a.chars.count != b.chars.count { return a.chars.count > b.chars.count }
            if a.replaces != b.replaces { return !a.replaces }
            return a.canonical < b.canonical
        }
        self.known = known
        self.wordSpanLookup = wordSpan
        self.maxSpanChars = maxSpan
        self.isEmpty = known.allSatisfy { !$0.replaces }
    }

    private static func normalize(_ s: String, isLatin: Bool) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return isLatin ? trimmed.lowercased() : trimmed
    }

    /// Replace every variant occurrence in `text` with its canonical, scanning left to right and
    /// taking the longest known match at each position. Latin matches respect word boundaries;
    /// CJK matches run character-to-character (nesting handled by longest-first).
    func correct(_ text: String) -> String {
        guard !isEmpty, !text.isEmpty else { return text }
        let chars = Array(text)
        var out = String()
        out.reserveCapacity(text.count)
        var i = 0
        while i < chars.count {
            if let m = match(chars, at: i) {
                out += m.replaces ? m.canonical : String(chars[i..<i + m.chars.count])
                i += m.chars.count
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    private func match(_ chars: [Character], at i: Int) -> Known? {
        for k in known {
            let n = k.chars.count
            guard i + n <= chars.count else { continue }
            var ok = true
            for offset in 0..<n {
                let a = chars[i + offset], b = k.chars[offset]
                if k.isLatin {
                    if a.lowercased() != b.lowercased() { ok = false; break }
                } else if a != b {
                    ok = false; break
                }
            }
            guard ok else { continue }
            // Latin word boundaries apply to a pure-Latin variant AND to the Latin edges of a
            // mixed-script one (else variant "AI技术" matches inside "OpenAI技术").
            let startsLatin = k.chars.first.map(GlossaryText.isLatinWordChar) ?? false
            let endsLatin = k.chars.last.map(GlossaryText.isLatinWordChar) ?? false
            if (k.isLatin || startsLatin), i > 0, GlossaryText.isLatinWordChar(chars[i - 1]) { continue }
            if k.isLatin || endsLatin {
                let after = i + n
                if after < chars.count, GlossaryText.isLatinWordChar(chars[after]) { continue }
            }
            return k
        }
        return nil
    }

    /// Replace variants that span whole word tokens (e.g. "black sushi" split across two words).
    /// Canonical lands in the first token; the rest are emptied so timings stay put.
    /// Returns nil-free tokens the same length as input.
    func correctWordSpans(_ tokens: [String]) -> [String] {
        guard !isEmpty, maxSpanChars > 0, tokens.count > 1 else { return tokens }
        var out: [String] = []
        out.reserveCapacity(tokens.count)
        var i = 0
        while i < tokens.count {
            var matched: (span: Int, canonical: String)?
            var joinedChars = 0
            var span = 0
            while i + span < tokens.count && joinedChars <= maxSpanChars {
                span += 1
                let slice = tokens[i..<i + span]
                joinedChars = slice.reduce(0) { $0 + $1.count }
                if joinedChars > maxSpanChars && span > 1 { break }
                let noSep = slice.joined()
                let spaced = slice.joined(separator: " ")
                if let canon = wordSpanLookup[Self.normalize(noSep, isLatin: !GlossaryText.isCJKPhrase(noSep))]
                    ?? wordSpanLookup[Self.normalize(spaced, isLatin: true)] {
                    matched = (span, canon)  // keep scanning for a longer span
                }
            }
            if let matched {
                out.append(matched.canonical)
                out.append(contentsOf: Array(repeating: "", count: matched.span - 1))
                i += matched.span
            } else {
                out.append(tokens[i])
                i += 1
            }
        }
        return out
    }
}
