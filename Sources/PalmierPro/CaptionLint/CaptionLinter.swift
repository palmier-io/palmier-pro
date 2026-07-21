// caption_lint core — flags suspected ASR word-substitution errors in caption text using the
// surrounding lines as context, or prepares judgeable windows for an external caller. Flags only;
// it never mutates. Terms other stages own (glossary, caption-style fillers) are masked out first.
// refs feature/caption-lint

import Foundation

/// One caption clip under lint, with its neighbours for context. Frames are project frames.
struct LintWindow: Sendable, Equatable {
    let clipId: String
    let startFrame: Int
    let endFrame: Int
    let text: String
    let prevText: String?
    let nextText: String?
}

/// A suspected word-substitution error. Nothing is applied from this alone.
struct LintCandidate: Sendable, Equatable {
    let clipId: String
    let startFrame: Int
    let endFrame: Int
    let original: String
    let suggestion: String
    let reason: String
    let confidence: Double
}

/// Terms that other stages already own — glossary variants/canonicals, caption-style filler lists
/// (removeAlways/caseByCase/neverRemove), and protected phrases. Masked out of lint candidacy so
/// caption_lint never re-flags what caption-style or the glossary is responsible for.
struct LintExclusions: Sendable {
    // Each term as its ordered token match-keys (punctuation-only tokens dropped).
    private let termKeySeqs: [[String]]
    // Surface forms, kept only to report which terms a window masks.
    private let termSurface: [String]

    init(terms: [String]) {
        var seqs: [[String]] = []
        var surface: [String] = []
        var seen = Set<String>()
        for term in terms {
            let keys = CaptionText.tokens(term).map(CaptionText.matchKey).filter { !$0.isEmpty }
            guard !keys.isEmpty, seen.insert(keys.joined(separator: "\u{1}")).inserted else { continue }
            seqs.append(keys)
            surface.append(term)
        }
        termKeySeqs = seqs
        termSurface = surface
    }

    /// Exclusion terms whose token sequence appears contiguously in `text`, for reporting.
    func presentTerms(in text: String) -> [String] {
        let textKeys = CaptionText.tokens(text).map(CaptionText.matchKey).filter { !$0.isEmpty }
        guard !textKeys.isEmpty else { return [] }
        var out: [String] = []
        for (i, seq) in termKeySeqs.enumerated() where CaptionLinter.containsSequence(textKeys, seq) {
            out.append(termSurface[i])
        }
        return out
    }

    /// True when the correction TOUCHES a term another stage owns — i.e. a changed token falls inside
    /// an excluded term's span. An excluded term sitting only in the unchanged surrounding tokens does
    /// not suppress the flag (开照片→拍照片 stays flagged even when 视频 or an adjacent 呃 is excluded).
    func excludesChange(original: String, suggestion: String) -> Bool {
        let origKeys = CaptionText.tokens(original).map(CaptionText.matchKey).filter { !$0.isEmpty }
        guard !origKeys.isEmpty else { return false }
        let sugKeys = CaptionText.tokens(suggestion).map(CaptionText.matchKey).filter { !$0.isEmpty }
        let changed = CaptionLinter.changedPositions(origKeys, sugKeys)
        guard !changed.isEmpty else { return false }
        for seq in termKeySeqs {
            for range in CaptionLinter.occurrences(of: seq, in: origKeys) where range.contains(where: changed.contains) {
                return true
            }
        }
        return false
    }
}

/// One-shot text completion used for mode:flags. Stubbed in tests so no network is needed.
protocol LintCompleter: Sendable {
    func complete(system: String, user: String) async throws -> String
}

enum CaptionLinter {
    enum Mode: String, Sendable, CaseIterable { case flags, context }

    // MARK: - context mode (no model call)

    /// Judgeable windows for the caller (itself an LLM) to lint, each carrying the terms this window
    /// masks. No model is called — this is the primary path when the app LLM is unavailable.
    static func contextSegments(windows: [LintWindow], exclusions: LintExclusions) -> [[String: Any]] {
        windows.map { w in
            var row: [String: Any] = [
                "clipId": w.clipId,
                "frameRange": [w.startFrame, w.endFrame],
                "text": w.text,
            ]
            if let p = w.prevText { row["prevText"] = p }
            if let n = w.nextText { row["nextText"] = n }
            let masked = exclusions.presentTerms(in: w.text)
            if !masked.isEmpty { row["exclusions"] = masked }
            return row
        }
    }

    /// Total masked-term occurrences across the windows — reported as skippedExclusions.
    static func maskedCount(windows: [LintWindow], exclusions: LintExclusions) -> Int {
        windows.reduce(0) { $0 + exclusions.presentTerms(in: $1.text).count }
    }

    // MARK: - flags mode (one model pass)

    static func flag(
        windows: [LintWindow],
        exclusions: LintExclusions,
        completer: LintCompleter
    ) async throws -> [LintCandidate] {
        let reviewable = windows.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !reviewable.isEmpty else { return [] }
        let raw = try await completer.complete(
            system: systemPrompt,
            user: userPrompt(windows: reviewable, exclusions: exclusions)
        )
        let byId = Dictionary(reviewable.map { ($0.clipId, $0) }, uniquingKeysWith: { first, _ in first })
        return parse(raw, windows: byId, exclusions: exclusions)
    }

    /// Split candidates by an auto-apply threshold. Without a threshold nothing is applied — every
    /// candidate stays a flag, so nothing changes unless the caller opts in.
    static func partition(_ candidates: [LintCandidate], threshold: Double?) -> (apply: [LintCandidate], flag: [LintCandidate]) {
        guard let threshold else { return ([], candidates) }
        var apply: [LintCandidate] = []
        var flag: [LintCandidate] = []
        for c in candidates {
            if c.confidence >= threshold { apply.append(c) } else { flag.append(c) }
        }
        return (apply, flag)
    }

    // MARK: - Prompt

    static let systemPrompt = """
    You proofread auto-generated video captions. Each line came from speech recognition and may hold a \
    WORD-SUBSTITUTION error: a near-sound mishearing (e.g. 开 kāi misheard for 拍 pāi), a wrong \
    homophone/character, or a word that does not fit the surrounding sentences. Use the previous and \
    next lines as context and flag ONLY suspected substitution errors.

    Rules:
    - Flag word substitutions only. Do NOT rephrase, fix grammar, change punctuation, add/delete words, \
    or otherwise "improve" wording.
    - Only flag when the context makes a specific corrected word likely. If unsure, do not flag.
    - Never flag a term listed under "exclusions" — other stages own those.
    - `original` must be copied verbatim from that line's text; `suggestion` is the single corrected word.
    - `confidence` is 0..1: your certainty this is a real recognition error given the context.

    Return ONLY a JSON array, no prose and no code fences. Each element:
    {"clipId": string, "original": string, "suggestion": string, "reason": short string, "confidence": number}
    If nothing is wrong, return [].
    """

    static func userPrompt(windows: [LintWindow], exclusions: LintExclusions) -> String {
        let lines = windows.map { w -> [String: Any] in
            var row: [String: Any] = ["clipId": w.clipId, "text": w.text]
            if let p = w.prevText { row["prevText"] = p }
            if let n = w.nextText { row["nextText"] = n }
            return row
        }
        var masked = Set<String>()
        for w in windows { for t in exclusions.presentTerms(in: w.text) { masked.insert(t) } }
        let obj: [String: Any] = ["lines": lines, "exclusions": masked.sorted()]
        return "Proofread these caption lines. Return the JSON array only.\n" + (jsonString(obj) ?? "{}")
    }

    // MARK: - Parsing

    private struct RawFlag: Decodable {
        let clipId: String
        let original: String
        let suggestion: String
        let reason: String?
        let confidence: Double?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            clipId = (try? c.decode(String.self, forKey: .clipId)) ?? ""
            original = (try? c.decode(String.self, forKey: .original)) ?? ""
            suggestion = (try? c.decode(String.self, forKey: .suggestion)) ?? ""
            reason = try? c.decodeIfPresent(String.self, forKey: .reason)
            if let d = try? c.decodeIfPresent(Double.self, forKey: .confidence) {
                confidence = d
            } else if let s = try? c.decodeIfPresent(String.self, forKey: .confidence) {
                confidence = Double(s)
            } else {
                confidence = nil
            }
        }

        enum CodingKeys: String, CodingKey { case clipId, original, suggestion, reason, confidence }
    }

    static func parse(_ raw: String, windows byId: [String: LintWindow], exclusions: LintExclusions) -> [LintCandidate] {
        guard let data = extractJSONArray(raw),
              let rows = try? JSONDecoder().decode([RawFlag].self, from: data) else { return [] }
        var out: [LintCandidate] = []
        for r in rows {
            guard let w = byId[r.clipId] else { continue }
            let original = r.original.trimmingCharacters(in: .whitespacesAndNewlines)
            let suggestion = r.suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !original.isEmpty, !suggestion.isEmpty, original != suggestion else { continue }
            // The flagged word must really be in that line, and the correction must not touch a term
            // another stage owns.
            guard textContains(w.text, original), !exclusions.excludesChange(original: original, suggestion: suggestion) else { continue }
            let reason = (r.reason?.isEmpty == false) ? r.reason! : "possible word-substitution error"
            out.append(LintCandidate(
                clipId: w.clipId, startFrame: w.startFrame, endFrame: w.endFrame,
                original: original, suggestion: suggestion, reason: reason,
                confidence: min(max(r.confidence ?? 0.5, 0), 1)
            ))
        }
        return out
    }

    /// True when `token`'s ordered match-keys appear contiguously in `text` — tolerant of case and
    /// punctuation so a verbatim-but-repunctuated flag still resolves.
    static func textContains(_ text: String, _ token: String) -> Bool {
        let hay = CaptionText.tokens(text).map(CaptionText.matchKey).filter { !$0.isEmpty }
        let needle = CaptionText.tokens(token).map(CaptionText.matchKey).filter { !$0.isEmpty }
        return containsSequence(hay, needle)
    }

    static func containsSequence(_ haystack: [String], _ needle: [String]) -> Bool {
        !occurrences(of: needle, in: haystack).isEmpty
    }

    /// Every contiguous index range where `needle` appears in `haystack`.
    static func occurrences(of needle: [String], in haystack: [String]) -> [Range<Int>] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var out: [Range<Int>] = []
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            out.append(start..<start + needle.count)
        }
        return out
    }

    /// Indices in `original` that the edit to `suggestion` changed — a common-prefix/suffix diff.
    /// A pure insertion (empty changed span) touches the two tokens straddling the insertion point.
    static func changedPositions(_ original: [String], _ suggestion: [String]) -> Set<Int> {
        let n = original.count, m = suggestion.count
        let bound = min(n, m)
        var prefix = 0
        while prefix < bound, original[prefix] == suggestion[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < bound - prefix, original[n - 1 - suffix] == suggestion[m - 1 - suffix] { suffix += 1 }
        let lo = prefix, hi = n - suffix
        if lo < hi { return Set(lo..<hi) }
        var touched = Set<Int>()
        if lo - 1 >= 0 { touched.insert(lo - 1) }
        if lo < n { touched.insert(lo) }
        return touched
    }

    private static func extractJSONArray(_ raw: String) -> Data? {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end else {
            return nil
        }
        return String(raw[start...end]).data(using: .utf8)
    }

    private static func jsonString(_ obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
