// Pure filler-policy engine over a resolved profile: classifies tokens and plans per-token
// remove/keep/flag decisions, honoring protected phrases and the neverDedupe grammar guards.
// Never auto-removes caseByCase tokens — those are surfaced for judgement.

import Foundation

enum FillerClassification: String, Equatable, Sendable {
    case removeAlways
    case neverRemove
    case caseByCase
    case none
}

enum FillerDecision: String, Equatable, Sendable {
    case remove
    case keep
    /// Requires judgement (caseByCase) — a tool must stop and surface it, never auto-remove.
    case flag
    /// An unguarded adjacent duplicate a dedup pass may drop.
    case removeDuplicate
}

struct FillerAction: Equatable, Sendable {
    let index: Int
    let token: String
    let classification: FillerClassification
    let decision: FillerDecision
    let reason: String
}

struct FillerPolicy: Sendable {
    let profile: CaptionStyleProfile
    private let removeAlwaysSet: Set<String>
    private let neverRemoveSet: Set<String>
    private let caseByCaseSet: Set<String>

    init(profile: CaptionStyleProfile) {
        self.profile = profile
        removeAlwaysSet = Set(profile.fillers.removeAlways.map(Self.normalize))
        neverRemoveSet = Set(profile.fillers.neverRemove.map(Self.normalize))
        caseByCaseSet = Set(profile.fillers.caseByCase.map(Self.normalize))
    }

    /// Classify a single token. removeAlways > neverRemove > caseByCase; anything else is none.
    func classify(_ token: String) -> FillerClassification {
        let t = Self.normalize(token)
        guard !t.isEmpty else { return .none }
        if removeAlwaysSet.contains(t) { return .removeAlways }
        if neverRemoveSet.contains(t) { return .neverRemove }
        if caseByCaseSet.contains(t) { return .caseByCase }
        return .none
    }

    /// Per-token decisions for a caption's words. Multi-word filler entries and protected phrases
    /// are matched as spans; adjacent duplicates are only removable when no grammar guard applies.
    func plan(words: [String]) -> [FillerAction] {
        let n = words.count
        guard n > 0 else { return [] }
        let norm = words.map(Self.normalize)
        var out = [FillerAction?](repeating: nil, count: n)

        // 1. Protected phrases win over everything — covered tokens are kept verbatim.
        markSpans(profile.protectedPhrases, norm: norm) { i in
            out[i] = FillerAction(index: i, token: words[i], classification: .none, decision: .keep, reason: "protectedPhrase")
        }

        // 2. Multi-word filler entries (e.g. "you know") matched as spans, in priority order.
        markFillerSpans(profile.fillers.removeAlways, classification: .removeAlways, decision: .remove, words: words, norm: norm, out: &out)
        markFillerSpans(profile.fillers.neverRemove, classification: .neverRemove, decision: .keep, words: words, norm: norm, out: &out)
        markFillerSpans(profile.fillers.caseByCase, classification: .caseByCase, decision: .flag, words: words, norm: norm, out: &out)

        // 3. Single-token classification for anything still unassigned.
        for i in 0..<n where out[i] == nil {
            switch classify(words[i]) {
            case .removeAlways:
                out[i] = FillerAction(index: i, token: words[i], classification: .removeAlways, decision: .remove, reason: "removeAlways")
            case .neverRemove:
                out[i] = FillerAction(index: i, token: words[i], classification: .neverRemove, decision: .keep, reason: "neverRemove")
            case .caseByCase:
                out[i] = FillerAction(index: i, token: words[i], classification: .caseByCase, decision: .flag, reason: "caseByCase")
            case .none:
                break
            }
        }

        // 4. Dedup pass over remaining unclassified tokens, guarded by neverDedupe rules.
        applyDedup(words: words, norm: norm, out: &out)

        // 5. Everything left is an ordinary kept word.
        for i in 0..<n where out[i] == nil {
            out[i] = FillerAction(index: i, token: words[i], classification: .none, decision: .keep, reason: "keep")
        }
        return out.compactMap { $0 }
    }

    /// A phrase (in `phrase.words` order) with removeAlways tokens dropped, or nil if nothing remains.
    /// Display-only: it rebuilds caption text and word timings; it never touches audio.
    func strippingRemoveAlways(_ phrase: CaptionBuilder.Phrase) -> CaptionBuilder.Phrase? {
        if !phrase.words.isEmpty {
            // Flatten each word's text with the shared tokenizer so single-character CJK fillers
            // match inside multi-character word blobs, then map decisions back per timing: a timing
            // is removed only when ALL its subtokens are removals (a timing cannot be split).
            let subtokens = phrase.words.map { Self.fallbackTokens($0.text) }
            let actions = plan(words: subtokens.flatMap { $0 })
            var cursor = 0
            var kept: [CaptionBuilder.WordSpan] = []
            for (word, tokens) in zip(phrase.words, subtokens) {
                let decisions = actions[cursor..<(cursor + tokens.count)]
                cursor += tokens.count
                if tokens.isEmpty || !decisions.allSatisfy({ $0.decision == .remove }) {
                    kept.append(word)
                }
            }
            guard let first = kept.first, let last = kept.last else { return nil }
            // CJK-aware rebuild: per-character word spans must not introduce spaces (你 好).
            let text = Self.joinTokens(kept.map(\.text))
            return CaptionBuilder.Phrase(text: text, start: first.start, end: last.end, words: kept)
        }
        // Whitespace splitting misses unsegmented CJK ("呃你好" arrives as one token, so a
        // single-character removeAlways entry like 呃 never matches). Split CJK per character,
        // keep Latin whitespace runs whole, and rejoin without spaces inside CJK runs.
        let tokens = Self.fallbackTokens(phrase.text)
        guard !tokens.isEmpty else { return phrase }
        let actions = plan(words: tokens)
        let kept = zip(tokens, actions).filter { $0.1.decision != .remove }.map(\.0)
        guard !kept.isEmpty else { return nil }
        return CaptionBuilder.Phrase(text: Self.joinTokens(kept), start: phrase.start, end: phrase.end)
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = Int(scalar.value)
        return ((0x2E80...0x9FFF).contains(value) && !(0x3000...0x303F).contains(value))
            || (0xF900...0xFAFF).contains(value)
    }

    private static func isCJKToken(_ token: String) -> Bool {
        token.count == 1 && token.unicodeScalars.allSatisfy(isCJKScalar)
    }

    static func fallbackTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var latin = ""
        for ch in text {
            if ch.isWhitespace {
                if !latin.isEmpty { tokens.append(latin); latin = "" }
            } else if ch.unicodeScalars.allSatisfy(isCJKScalar) {
                if !latin.isEmpty { tokens.append(latin); latin = "" }
                tokens.append(String(ch))
            } else {
                latin.append(ch)
            }
        }
        if !latin.isEmpty { tokens.append(latin) }
        return tokens
    }

    static func joinTokens(_ tokens: [String]) -> String {
        var out = ""
        var prevCJK = false
        for token in tokens {
            let cjk = isCJKToken(token)
            if !out.isEmpty, !(cjk && prevCJK) { out += " " }
            out += token
            prevCJK = cjk
        }
        return out
    }

    // MARK: - Helpers

    static func normalize(_ token: String) -> String {
        token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: strippedPunctuation)
            .lowercased()
    }

    private static let strippedPunctuation: CharacterSet = {
        var set = CharacterSet.punctuationCharacters
        set.formUnion(.symbols)
        return set
    }()

    static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { sc in
            (0x4E00...0x9FFF).contains(sc.value)   // CJK unified ideographs
                || (0x3400...0x4DBF).contains(sc.value) // extension A
                || (0x3040...0x30FF).contains(sc.value) // hiragana + katakana
        }
    }

    /// Split a possibly multi-token phrase into its normalized parts.
    private static func parts(_ phrase: String) -> [String] {
        phrase.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }.filter { !$0.isEmpty }
    }

    /// Both tokenizations of a phrase, so span matching works against whitespace-token streams
    /// (CaptionBuilder words, blobs) AND per-character CJK streams (the fallback/flattened paths).
    private static func candidateForms(_ phrase: String) -> [[String]] {
        let whitespace = parts(phrase)
        let perChar = fallbackTokens(phrase).map { normalize($0) }.filter { !$0.isEmpty }
        return whitespace == perChar ? [whitespace] : [whitespace, perChar]
    }

    private func markSpans(_ phrases: [String], norm: [String], mark: (Int) -> Void) {
        let candidates = phrases.flatMap(Self.candidateForms).filter { !$0.isEmpty }
        var i = 0
        while i < norm.count {
            if let len = matchAt(i, norm: norm, candidates: candidates) {
                for j in i..<(i + len) { mark(j) }
                i += len
            } else {
                i += 1
            }
        }
    }

    private func markFillerSpans(
        _ phrases: [String],
        classification: FillerClassification,
        decision: FillerDecision,
        words: [String],
        norm: [String],
        out: inout [FillerAction?]
    ) {
        // Only multi-token entries need span matching; single tokens are handled per-token later.
        // Entries are matched in BOTH tokenizations (whitespace and per-character CJK), so a
        // multi-character entry like 嗯嗯 strips whether the stream carries it as one blob or
        // as flattened per-character tokens.
        let multiword = phrases.flatMap(Self.candidateForms).filter { $0.count > 1 }
        guard !multiword.isEmpty else { return }
        var i = 0
        while i < norm.count {
            if out[i] == nil, let len = matchAt(i, norm: norm, candidates: multiword),
               (i..<(i + len)).allSatisfy({ out[$0] == nil }) {
                for j in i..<(i + len) {
                    out[j] = FillerAction(index: j, token: words[j], classification: classification, decision: decision, reason: classification.rawValue)
                }
                i += len
            } else {
                i += 1
            }
        }
    }

    /// Longest candidate whose parts match `norm` starting at `start`; nil if none.
    private func matchAt(_ start: Int, norm: [String], candidates: [[String]]) -> Int? {
        var best: Int?
        for cand in candidates {
            let len = cand.count
            guard start + len <= norm.count else { continue }
            if Array(norm[start..<start + len]) == cand, len > (best ?? 0) {
                best = len
            }
        }
        return best
    }

    private func applyDedup(words: [String], norm: [String], out: inout [FillerAction?]) {
        let guardCJK = profile.fillers.neverDedupe.cjkReduplication
        let guardComic = profile.fillers.neverDedupe.comicRepetition

        var i = 0
        while i < norm.count {
            guard out[i] == nil, !norm[i].isEmpty else { i += 1; continue }
            // Measure the run of identical adjacent tokens starting at i.
            var end = i + 1
            while end < norm.count, norm[end] == norm[i] { end += 1 }
            let runLength = end - i
            if runLength >= 2 {
                let isCJK = Self.containsCJK(norm[i])
                let isComic = runLength >= 3
                let guarded = (isCJK && guardCJK) || (isComic && guardComic)
                for j in i..<end where out[j] == nil {
                    if guarded {
                        let reason = isCJK ? "cjkReduplication" : "comicRepetition"
                        out[j] = FillerAction(index: j, token: words[j], classification: .none, decision: .keep, reason: reason)
                    } else if j > i {
                        // Keep the first occurrence; later exact repeats are removable duplicates.
                        out[j] = FillerAction(index: j, token: words[j], classification: .none, decision: .removeDuplicate, reason: "duplicate")
                    }
                }
            }
            i = end
        }
    }
}
