import Foundation

enum CaptionBuilder {
    struct Phrase: Equatable {
        var text: String
        var start: Double
        var end: Double
    }

    /// Splits a transcript segment into screen-ready phrases and times them.
    static func phrases(
        for segment: TranscriptionSegment,
        fits: (String) -> Bool,
        minDuration: Double
    ) -> [Phrase] {
        let pieces = split(segment.text, fits: fits)
        let timed = distribute(pieces, start: segment.start, end: segment.end)
        return enforceMinDuration(timed, minDuration: minDuration)
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
        transformFor: (String) -> Transform? = { _ in nil },
        minDurationFrames: Int = 1
    ) -> [EditorViewModel.TextClipSpec] {
        phrases.compactMap { p in
            let visibleStartSource = Double(sourceClip.trimStartFrame)
            let visibleEndSource = visibleStartSource + Double(sourceClip.durationFrames) * max(sourceClip.speed, 0.0001)
            let phraseStartSource = p.start * Double(fps)
            let phraseEndSource = p.end * Double(fps)
            guard phraseEndSource > visibleStartSource, phraseStartSource < visibleEndSource else { return nil }

            let mappedStart = sourceClip.timelineFrame(sourceSeconds: p.start, fps: fps)
            let mappedEnd = sourceClip.timelineFrame(sourceSeconds: p.end, fps: fps)
            let s = mappedStart ?? sourceClip.startFrame
            let e = mappedEnd ?? sourceClip.endFrame
            return EditorViewModel.TextClipSpec(
                trackIndex: trackIndex,
                startFrame: s,
                durationFrames: max(minDurationFrames, min(sourceClip.endFrame, e) - max(sourceClip.startFrame, s)),
                content: p.text,
                style: style,
                transform: transformFor(p.text),
                captionGroupId: captionGroupId
            )
        }
    }
}
