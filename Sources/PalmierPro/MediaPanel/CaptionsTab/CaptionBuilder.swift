import Foundation
import NaturalLanguage

// Purpose: Decides how words from CaptionTranscriptMapper should be grouped into chunks
enum CaptionBuilder {
    /// How a run of transcript text is cut into caption lines.
    enum Segmentation: String, Sendable, CaseIterable {
        /// Break at sentence/clause punctuation and word-token boundaries, preferring shorter lines.
        case natural
        /// Legacy recursive sentence→clause→mid-word width split (kept for callers that depend on it).
        case fixedChars

        static let `default`: Segmentation = .natural
    }

    struct Phrase: Equatable {
        var text: String
        var start: Double
        var end: Double
        /// Member words with their own timings (seconds); empty when word timing is unavailable.
        var words: [WordSpan] = []
    }

    struct WordSpan: Equatable {
        var text: String
        var start: Double
        var end: Double
        var aligned: Bool?
    }

    /// General builder: split a transcript segment into caption-sized chunks
    static func phrases(
        for segment: TranscriptionSegment,
        words: [TranscriptionWord] = [],
        fits: (String) -> Bool,
        maxWords: Int? = nil,
        minDuration: Double,
        segmentation: Segmentation = .default,
        protectedPhrases: [String] = [],
        punctuation: CaptionText.PunctuationPolicy = .keep
    ) -> [Phrase] {
        // Only phrases that fit visually and within the word cap are accepted; else, keep splitting.
        let pieces: [String]
        switch segmentation {
        case .fixedChars:
            if let limit = maxWords {
                let cap = max(1, limit)
                pieces = split(segment.text, fits: { fits($0) && wordCount($0) <= cap })
            } else {
                pieces = split(segment.text, fits: fits)
            }
        case .natural:
            pieces = naturalLines(segment.text, fits: fits, maxWords: maxWords, protectedPhrases: protectedPhrases)
        }
        let timed = time(pieces, segment: segment, words: words)
        let floored = enforceMinDuration(timed, minDuration: minDuration)
        // Marks drove the break decisions above; the display policy decides whether they stay visible.
        return segmentation == .natural ? strippingMarks(floored, policy: punctuation) : floored
    }

    static func phrases(
        fromTimedWords words: [TranscriptionWord],
        fits: (String) -> Bool,
        maxWords: Int? = nil,
        minDuration: Double,
        segmentation: Segmentation = .default,
        protectedPhrases: [String] = [],
        punctuation: CaptionText.PunctuationPolicy = .keep
    ) -> [Phrase] {
        let timed = words.filter { $0.start != nil && $0.end != nil }
        guard !timed.isEmpty else { return [] }
        // A real speech pause is an unconditional line break: split the word stream at pauses and
        // segment each run alone, so no line ever merges across silence. Pause breaks compose with
        // punctuation breaks — either triggers. This runs BEFORE phrase protection, so a pause also
        // overrides it: real silence inside a protected term (城南<gap>西站) splits it, on the premise
        // that a genuine pause mid-term means the match was wrong. fixedChars keeps its legacy shape.
        let runs = segmentation == .natural ? splitAtPauses(timed) : [timed]
        let built = runs.flatMap {
            phrasesForRun($0, fits: fits, maxWords: maxWords, minDuration: minDuration,
                          segmentation: segmentation, protectedPhrases: protectedPhrases,
                          punctuation: punctuation)
        }
        return runs.count > 1 ? enforceMinDuration(built, minDuration: minDuration) : built
    }

    /// Join one run of timed words into a segment and cut it into phrases.
    private static func phrasesForRun(
        _ timed: [TranscriptionWord],
        fits: (String) -> Bool,
        maxWords: Int?,
        minDuration: Double,
        segmentation: Segmentation,
        protectedPhrases: [String],
        punctuation: CaptionText.PunctuationPolicy = .keep
    ) -> [Phrase] {
        // A collapsed span (a zero-duration word isolated by a pause split) must still emit — dropping
        // it would silently lose that word from the captions. enforceMinDuration floors its length.
        guard let first = timed.first, let last = timed.last,
              let start = first.start, let end0 = last.end else { return [] }
        let end = max(end0, start)
        // Drop empty tokens (a multi-token glossary variant empties the span's tail). Legacy mode joins
        // on spaces; natural mode glues CJK runs so re-tokenisation sees words, not spaced characters.
        let tokens = timed.map(\.text).filter { !$0.isEmpty }
        let joined = segmentation == .fixedChars ? tokens.joined(separator: " ") : cjkAwareJoin(tokens)
        let text = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return phrases(
            for: TranscriptionSegment(text: text, start: start, end: end, speaker: first.speaker),
            words: timed,
            fits: fits,
            maxWords: maxWords,
            minDuration: minDuration,
            segmentation: segmentation,
            protectedPhrases: protectedPhrases,
            punctuation: punctuation
        )
    }

    /// Strip marks from phrase text and word tokens per the display policy. Tokens that empty out
    /// (a standalone mark) are dropped; a phrase that empties out is dropped whole.
    private static func strippingMarks(_ phrases: [Phrase], policy: CaptionText.PunctuationPolicy) -> [Phrase] {
        guard policy != .keep else { return phrases }
        return phrases.compactMap { phrase in
            var p = phrase
            p.words = phrase.words.compactMap { span in
                let stripped = CaptionText.strippingMarks(span.text, policy: policy)
                guard !stripped.isEmpty else { return nil }
                var s = span
                s.text = stripped
                return s
            }
            let tokens = phrase.text.split(separator: " ").map {
                CaptionText.strippingMarks(String($0), policy: policy)
            }.filter { !$0.isEmpty }
            p.text = CaptionText.join(tokens)
            return p.text.isEmpty ? nil : p
        }
    }

    /// A gap between consecutive words of at least this long reads as a deliberate pause, not the
    /// micro-silence between syllables. ~12 frames at 30 fps — the shortest break worth cutting on.
    private static let pauseBreakSeconds = 0.4

    /// Split a word run wherever consecutive words are separated by a real pause. Only genuine gaps
    /// (anchored timings) exceed the threshold; interpolated words sit back-to-back, so they don't cut.
    private static func splitAtPauses(_ words: [TranscriptionWord]) -> [[TranscriptionWord]] {
        var runs: [[TranscriptionWord]] = []
        var current: [TranscriptionWord] = []
        var previousEnd: Double?
        for word in words {
            if let previousEnd, let start = word.start, start - previousEnd >= pauseBreakSeconds, !current.isEmpty {
                runs.append(current)
                current = []
            }
            current.append(word)
            if let end = word.end { previousEnd = end }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    // MARK: - Natural segmentation

    /// Sentence/clause marks that end a caption line, bound to the preceding line, never starting the next.
    private static let hardBreakPunct: Set<Character> = ["。", "？", "！", "，", "、", "；", "…", ".", "?", "!", ","]
    private static let asciiHardBreak: Set<Character> = [".", "?", "!", ","]

    /// Cut into shortest natural lines: hard breaks then word-token boundaries; content preserved.
    /// Protected phrases (glossary terms, caption-style phrases) are atomic WITHIN a run — a term like
    /// 城南西站 is one unbreakable token even under a tight cap, so a line breaks before it rather than
    /// through it. A real speech pause splits the stream upstream of this, so it can override protection.
    private static func naturalLines(
        _ text: String, fits: (String) -> Bool, maxWords: Int?, protectedPhrases: [String] = []
    ) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokens = wordTokenStarts(in: trimmed, protecting: protectedPhrases)
        var lines: [String] = []
        var current = ""

        func flush() {
            let line = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
            current = ""
        }

        var i = trimmed.startIndex
        while i < trimmed.endIndex {
            if let range = tokens[i] {
                let token = String(trimmed[range])
                let candidate = current + token
                let fitted = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   exceedsCap(fitted, maxWords) || !fits(fitted) {
                    flush()
                    current = token
                } else {
                    current = candidate
                }
                i = range.upperBound
                continue
            }

            let c = trimmed[i]
            let next = trimmed.index(after: i)
            if c.isWhitespace {
                if !current.isEmpty { current.append(c) }   // keep interior spacing, drop leading space
            } else {
                current.append(c)
                if isHardBreak(c, nextChar: next < trimmed.endIndex ? trimmed[next] : nil) {
                    flush()
                }
            }
            i = next
        }
        flush()
        return mergePunctuationOnly(lines)
    }

    /// Fold punctuation-only lines (a hard-break run like "。。。") into a neighbour so they never stand
    /// alone: bind to the preceding line, or the following one when they lead. Without this a run of marks
    /// explodes into one zero-word line each, and time() can't anchor them to any word.
    private static func mergePunctuationOnly(_ lines: [String]) -> [String] {
        guard lines.count > 1 else { return lines }
        var result: [String] = []
        for line in lines {
            if alphanumericCount(line) == 0, let last = result.last {
                result[result.count - 1] = last + line   // punctuation binds left — no separator
            } else {
                result.append(line)
            }
        }
        if result.count > 1, alphanumericCount(result[0]) == 0 {
            result[1] = result[0] + result[1]
            result.removeFirst()
        }
        return result
    }

    private static func isHardBreak(_ c: Character, nextChar: Character?) -> Bool {
        guard hardBreakPunct.contains(c) else { return false }
        // ASCII marks end a line only before whitespace or end-of-text, so "U.S." and "3.14" stay intact.
        guard asciiHardBreak.contains(c) else { return true }
        guard let n = nextChar else { return true }
        return n.isWhitespace
    }

    /// Cap counts characters for CJK-bearing lines, words for Latin — what callers mean by maxWords.
    private static func exceedsCap(_ line: String, _ maxWords: Int?) -> Bool {
        guard let cap = maxWords else { return false }
        if line.contains(where: GlossaryText.isCJK) {
            return alphanumericCount(line) > cap
        }
        return wordCount(line) > cap
    }

    /// Word tokens keyed by start index. Protected phrases override the tokenizer: each becomes one
    /// atomic token, and any tokenizer token overlapping a protected span is clipped to its
    /// outside-the-span remainder so every original character stays covered by exactly one token.
    private static func wordTokenStarts(
        in text: String, protecting protectedPhrases: [String] = []
    ) -> [String.Index: Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(range)
            return true
        }

        let spans = protectedSpans(in: text, phrases: protectedPhrases)
        if !spans.isEmpty {
            ranges = spans + ranges.flatMap { subtracting(spans, from: $0) }
        }

        var map: [String.Index: Range<String.Index>] = [:]
        for range in ranges { map[range.lowerBound] = range }
        return map
    }

    /// Longest-match, non-overlapping character ranges of `text` covered by a protected phrase,
    /// scanning left to right and preferring the longest phrase that starts at each position.
    private static func protectedSpans(in text: String, phrases: [String]) -> [Range<String.Index>] {
        let needles = phrases.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        guard !needles.isEmpty else { return [] }
        var spans: [Range<String.Index>] = []
        var i = text.startIndex
        while i < text.endIndex {
            if let match = needles.first(where: { text[i...].hasPrefix($0) }) {
                let end = text.index(i, offsetBy: match.count)
                spans.append(i..<end)
                i = end
            } else {
                i = text.index(after: i)
            }
        }
        return spans
    }

    /// The parts of `range` not covered by any protected span, so a tokenizer token that straddles a
    /// span boundary keeps its outside characters as tokens instead of being dropped.
    private static func subtracting(
        _ spans: [Range<String.Index>], from range: Range<String.Index>
    ) -> [Range<String.Index>] {
        var pieces: [Range<String.Index>] = []
        var cursor = range.lowerBound
        for span in spans where span.lowerBound < range.upperBound && span.upperBound > range.lowerBound {
            let lo = max(span.lowerBound, range.lowerBound)
            if cursor < lo { pieces.append(cursor..<lo) }
            cursor = max(cursor, min(span.upperBound, range.upperBound))
        }
        if cursor < range.upperBound { pieces.append(cursor..<range.upperBound) }
        return pieces
    }

    private static func cjkAwareJoin(_ tokens: [String]) -> String {
        CaptionText.join(tokens)
    }

    private static func split(_ text: String, fits: (String) -> Bool) -> [String] {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return [] }
        if fits(t) { return [t] }
        let parts = breakOnce(t)
        guard parts.count > 1 else { return [t] }   // a single over-long word: keep it
        return parts.flatMap { split($0, fits: fits) }
    }

    /// Break once at the best boundary present: sentence, then clause, then midpoint word.
    private static func breakOnce(_ text: String) -> [String] {
        breakOn(text, delimiters: ".!?") ?? breakOn(text, delimiters: ",;:") ?? breakAtMidWord(text)
    }

    /// Split after delimiters followed by a space, so "U.S." and "3.14" stay intact.
    private static func breakOn(_ text: String, delimiters: String) -> [String]? {
        let set = Set(delimiters)
        let chars = Array(text)
        var pieces: [String] = []
        var current = ""
        for (i, c) in chars.enumerated() {
            current.append(c)
            let nextIsBreak = i + 1 >= chars.count || chars[i + 1] == " "
            if set.contains(c), nextIsBreak {
                let piece = current.trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty { pieces.append(piece) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces.count > 1 ? pieces : nil
    }

    private static func breakAtMidWord(_ text: String) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        guard words.count > 1 else { return [text] }
        let mid = words.count / 2
        return [words[..<mid].joined(separator: " "), words[mid...].joined(separator: " ")]
    }

    /// Time phrases from word runs by matching shared characters, so timing holds when
    /// runs don't split on spaces (contractions, split numbers, punctuation runs).
    private static func time(_ texts: [String], segment: TranscriptionSegment, words: [TranscriptionWord]) -> [Phrase] {
        let timed = words.compactMap { w -> (text: String, count: Int, start: Double, end: Double, aligned: Bool?)? in
            guard let s = w.start, let e = w.end else { return nil }
            let count = alphanumericCount(w.text)
            return count > 0 ? (w.text, count, s, e, w.aligned) : nil
        }
        guard !timed.isEmpty else { return distribute(texts, start: segment.start, end: segment.end) }

        var phrases: [Phrase] = []
        var idx = 0
        for text in texts {
            let want = alphanumericCount(text)
            var got = 0
            var first: (start: Double, end: Double)?
            var last: (start: Double, end: Double)?
            var spans: [WordSpan] = []
            while idx < timed.count, got < want {
                let run = timed[idx]
                if first == nil { first = (run.start, run.end) }
                last = (run.start, run.end)
                spans.append(WordSpan(text: run.text.trimmingCharacters(in: .whitespaces), start: run.start, end: run.end, aligned: run.aligned))
                got += run.count
                idx += 1
            }
            guard let f = first, let l = last else {
                // Zero-alphanumeric line (a stray punctuation run): anchor a degenerate span to the
                // previous phrase's end and continue — one such line must not collapse the whole
                // segment to distribute() and throw away every other line's acoustic timing.
                let anchor = phrases.last?.end ?? segment.start
                phrases.append(Phrase(text: text, start: anchor, end: anchor))
                continue
            }
            phrases.append(Phrase(text: text, start: f.start, end: l.end, words: spans))
        }
        return phrases.count == texts.count ? phrases : distribute(texts, start: segment.start, end: segment.end)
    }

    private static func alphanumericCount(_ text: String) -> Int {
        text.reduce(0) { $0 + ($1.isLetter || $1.isNumber ? 1 : 0) }
    }

    /// Share the segment's time across pieces by character count, back to back.
    private static func distribute(_ texts: [String], start: Double, end: Double) -> [Phrase] {
        guard !texts.isEmpty else { return [] }
        let total = texts.reduce(0) { $0 + max($1.count, 1) }
        let span = max(end - start, 0)
        var phrases: [Phrase] = []
        var t = start
        for text in texts {
            let dur = span * Double(max(text.count, 1)) / Double(total)
            phrases.append(Phrase(text: text, start: t, end: t + dur))
            t += dur
        }
        return phrases
    }

    /// Give each phrase a floor duration without moving later phrases off their first word.
    private static func enforceMinDuration(_ phrases: [Phrase], minDuration: Double) -> [Phrase] {
        var out = phrases
        for i in out.indices {
            let targetEnd = max(out[i].end, out[i].start + minDuration)
            if i + 1 < out.count {
                out[i].end = min(targetEnd, out[i + 1].start)
                if out[i].end < out[i].start { out[i].end = out[i].start }
            } else {
                out[i].end = targetEnd
            }
        }
        return out
    }

    static func specs(
        for phrases: [Phrase],
        sourceClip: Clip,
        trackIndex: Int,
        fps: Int,
        style: TextStyle,
        captionGroupId: String?,
        animation: TextAnimation? = nil,
        transformFor: (String) -> Transform? = { _ in nil },
        minDurationFrames: Int = 1
    ) -> [EditorViewModel.TextClipSpec] {
        phrases.compactMap { p in
            let visibleStartSource = Double(sourceClip.trimStartFrame)
            let visibleEndSource = visibleStartSource + Double(sourceClip.durationFrames) * max(sourceClip.speed, 0.0001)
            let phraseStartSource = p.start * Double(fps)
            let phraseEndSource = p.end * Double(fps)
            guard phraseEndSource > visibleStartSource, phraseStartSource < visibleEndSource else { return nil }

            func clampedTimelineFrame(sourceSeconds: Double) -> Int {
                let sourceFrame = sourceSeconds * Double(fps)
                let offsetFromTrim = sourceFrame - visibleStartSource
                let frame = Int((Double(sourceClip.startFrame) + offsetFromTrim / max(sourceClip.speed, 0.0001)).rounded())
                return min(max(frame, sourceClip.startFrame), sourceClip.endFrame)
            }

            let mappedStart = sourceClip.timelineFrame(sourceSeconds: p.start, fps: fps)
            let mappedEnd = sourceClip.timelineFrame(sourceSeconds: p.end, fps: fps)
            let s = mappedStart ?? sourceClip.startFrame
            let e = mappedEnd ?? sourceClip.endFrame
            let duration = max(minDurationFrames, min(sourceClip.endFrame, e) - max(sourceClip.startFrame, s))

            // Map word spans to clip-relative frames, clamped to the clip's own span.
            let words: [WordTiming] = p.words.compactMap { w in
                let wordStartSource = w.start * Double(fps)
                let wordEndSource = w.end * Double(fps)
                guard wordEndSource > visibleStartSource, wordStartSource < visibleEndSource else { return nil }
                let ws = clampedTimelineFrame(sourceSeconds: w.start)
                let we = clampedTimelineFrame(sourceSeconds: w.end)
                let rs = min(max(0, ws - s), duration)
                let re = min(max(rs, we - s), duration)
                guard re > rs else { return nil }
                return WordTiming(text: w.text, startFrame: rs, endFrame: re, aligned: w.aligned)
            }

            return EditorViewModel.TextClipSpec(
                trackIndex: trackIndex,
                startFrame: s,
                durationFrames: duration,
                content: p.text,
                style: style,
                transform: transformFor(p.text),
                captionGroupId: captionGroupId,
                words: words.isEmpty ? nil : words,
                animation: animation,
                generatedText: captionGroupId == nil ? nil : p.text
            )
        }
    }
}
