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
    }

    /// General builder: split a transcript segment into caption-sized chunks
    static func phrases(
        for segment: TranscriptionSegment,
        words: [TranscriptionWord] = [],
        fits: (String) -> Bool,
        maxWords: Int? = nil,
        minDuration: Double,
        segmentation: Segmentation = .default
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
            pieces = naturalLines(segment.text, fits: fits, maxWords: maxWords)
        }
        let timed = time(pieces, segment: segment, words: words)
        return enforceMinDuration(timed, minDuration: minDuration)
    }

    static func phrases(
        fromTimedWords words: [TranscriptionWord],
        fits: (String) -> Bool,
        maxWords: Int? = nil,
        minDuration: Double,
        segmentation: Segmentation = .default
    ) -> [Phrase] {
        let timed = words.filter { $0.start != nil && $0.end != nil }
        guard let first = timed.first, let last = timed.last, let start = first.start, let end = last.end, end > start else { return [] }
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
            segmentation: segmentation
        )
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    // MARK: - Natural segmentation

    /// Sentence/clause marks that end a caption line, bound to the preceding line, never starting the next.
    private static let hardBreakPunct: Set<Character> = ["。", "？", "！", "，", "、", "；", "…", ".", "?", "!", ","]
    private static let asciiHardBreak: Set<Character> = [".", "?", "!", ","]

    /// Cut into shortest natural lines: hard breaks then word-token boundaries; content preserved.
    /// No NER — under a tight cap a run splits at the NLTokenizer seam (城南|西站), only mid-token is prevented.
    private static func naturalLines(_ text: String, fits: (String) -> Bool, maxWords: Int?) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokens = wordTokenStarts(in: trimmed)
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
        return lines
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

    private static func wordTokenStarts(in text: String) -> [String.Index: Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var map: [String.Index: Range<String.Index>] = [:]
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            map[range.lowerBound] = range
            return true
        }
        return map
    }

    /// Join tokens cleanly: no space inside a CJK run or before punctuation, one space at Latin/seam gaps.
    private static func cjkAwareJoin(_ tokens: [String]) -> String {
        var out = ""
        for token in tokens where !token.isEmpty {
            guard let prev = out.last, let cur = token.first else { out += token; continue }
            let glue = (isCJKContext(prev) && isCJKContext(cur)) || bindsLeft(cur)
            out += glue ? token : " " + token
        }
        return out
    }

    private static func isCJKContext(_ c: Character) -> Bool {
        GlossaryText.isCJK(c) || isFullwidthPunct(c)
    }

    private static func isFullwidthPunct(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }

    /// Punctuation that attaches to the token on its left — never spaced off it, never starting a line.
    private static func bindsLeft(_ c: Character) -> Bool {
        if hardBreakPunct.contains(c) { return true }
        if isFullwidthPunct(c) { return true }
        return ":;)]}".contains(c)
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
        let timed = words.compactMap { w -> (text: String, count: Int, start: Double, end: Double)? in
            guard let s = w.start, let e = w.end else { return nil }
            let count = alphanumericCount(w.text)
            return count > 0 ? (w.text, count, s, e) : nil
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
                spans.append(WordSpan(text: run.text.trimmingCharacters(in: .whitespaces), start: run.start, end: run.end))
                got += run.count
                idx += 1
            }
            guard let f = first, let l = last else { break }
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
                return WordTiming(text: w.text, startFrame: rs, endFrame: re)
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
