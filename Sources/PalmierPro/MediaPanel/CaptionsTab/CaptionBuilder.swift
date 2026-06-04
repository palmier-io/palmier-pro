import Foundation

enum CaptionBuilder {
    struct Phrase: Equatable {
        var text: String
        var start: Double
        var end: Double
    }

    static func group(
        _ words: [TranscriptionWord],
        fits: (String) -> Bool,
        hardWordCap: Int = 12,
        splitGap: Double = 0.8
    ) -> [Phrase] {
        var phrases: [Phrase] = []
        var bucket: [TranscriptionWord] = []
        var start: Double?
        var prevEnd: Double?

        func flush() {
            guard !bucket.isEmpty else { return }
            let text = joinWords(bucket)
            if !text.isEmpty {
                phrases.append(Phrase(text: text, start: start ?? 0, end: prevEnd ?? start ?? 0))
            }
            bucket.removeAll(keepingCapacity: true)
            start = nil
        }

        for w in words {
            let gap = (w.start.flatMap { s in prevEnd.map { s - $0 } }) ?? 0
            let overflow = !bucket.isEmpty && !fits(joinWords(bucket + [w]))
            if !bucket.isEmpty, gap > splitGap || bucket.count >= hardWordCap || overflow {
                flush()
            }
            if start == nil { start = w.start ?? prevEnd }
            bucket.append(w)
            if let e = w.end { prevEnd = e }
            if endsSentence(w.text) { flush() }
        }
        flush()
        return phrases
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

    private static func endsSentence(_ s: String) -> Bool {
        guard let last = s.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".!?".contains(last)
    }

    private static func joinWords(_ words: [TranscriptionWord]) -> String {
        var out = ""
        for w in words {
            let t = w.text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if out.isEmpty || (t.first.map { ",.!?;:".contains($0) } ?? false) {
                out += t
            } else {
                out += " " + t
            }
        }
        return out
    }
}
