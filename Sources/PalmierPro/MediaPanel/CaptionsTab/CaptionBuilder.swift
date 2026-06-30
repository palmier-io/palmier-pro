import Foundation

enum CaptionBuilder {
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

    /// Splits a transcript segment into screen-ready phrases and times them.
    static func phrases(
        for segment: TranscriptionSegment,
        words: [TranscriptionWord] = [],
        fits: (String) -> Bool,
        maxWords: Int? = nil,
        minDuration: Double
    ) -> [Phrase] {
        // Only phrases that fit visually and within the word cap are accepted; else, keep splitting.
        let pieces: [String]
        if let limit = maxWords {
            let cap = max(1, limit)
            pieces = split(segment.text, fits: { fits($0) && wordCount($0) <= cap })
        } else {
            pieces = split(segment.text, fits: fits)
        }
        let timed = time(pieces, segment: segment, words: words)
        return enforceMinDuration(timed, minDuration: minDuration)
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
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

    /// Give each phrase a floor duration, shifting later ones so they don't overlap.
    private static func enforceMinDuration(_ phrases: [Phrase], minDuration: Double) -> [Phrase] {
        var out = phrases
        for i in out.indices {
            if out[i].end - out[i].start < minDuration {
                out[i].end = out[i].start + minDuration
            }
            if i + 1 < out.count, out[i + 1].start < out[i].end {
                let shift = out[i].end - out[i + 1].start
                out[i + 1].start += shift
                out[i + 1].end += shift
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
                animation: animation
            )
        }
    }
}
