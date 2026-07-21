import Foundation

// Purpose: Given this source clip fragment, which transcript words/segments should become caption phrases?
enum CaptionTranscriptMapper {
    static func sourceSpan(for clip: Clip) -> (start: Double, end: Double) {
        let start = Double(clip.trimStartFrame)
        return (start, start + Double(clip.durationFrames) * max(clip.speed, 0.0001))
    }

    static func sourceUnion(for mediaRef: String, clips: [Clip], fps: Int, paddingSeconds: Double = 1.0) -> ClosedRange<Double>? {
        let rate = Double(fps)
        let spans = clips.filter { $0.mediaRef == mediaRef }.map { sourceSpan(for: $0) }
        guard rate > 0, let lo = spans.map(\.start).min(), let hi = spans.map(\.end).max(), hi > lo else { return nil }
        return max(lo / rate - paddingSeconds, 0)...(hi / rate + paddingSeconds)
    }

    /// Map a source-seconds span to project frames through this clip's placement, trim, and speed.
    /// Shared by get_transcript and caption resync so both compute identical timing.
    static func timelineFrames(sourceStart start: Double, sourceEnd end: Double, clip: Clip, fps: Int) -> (start: Int, end: Int)? {
        let rate = Double(fps)
        let visible = sourceSpan(for: clip)
        let startFrame = max(start * rate, visible.start)
        let endFrame = min(end * rate, visible.end)
        guard endFrame > startFrame else { return nil }
        func toTimeline(_ sourceFrame: Double) -> Int {
            Int((Double(clip.startFrame) + (sourceFrame - visible.start) / max(clip.speed, 0.0001)).rounded())
        }
        let mappedStart = toTimeline(startFrame)
        return (mappedStart, max(mappedStart, toTimeline(endFrame)))
    }

    /// Transcript words landing within this clip's visible span, mapped to absolute project frames.
    /// Cache-only callers pass a cached transcript; nothing here triggers transcription.
    static func timelineWords(from transcript: TranscriptionResult, clip: Clip, fps: Int) -> [WordTiming] {
        let visible = sourceSpan(for: clip)
        let rate = Double(fps)
        return transcript.words.compactMap { word -> WordTiming? in
            guard let start = word.start, let end = word.end else { return nil }
            let midFrame = (start + end) / 2 * rate
            guard midFrame >= visible.start, midFrame < visible.end,
                  let f = timelineFrames(sourceStart: start, sourceEnd: end, clip: clip, fps: fps) else { return nil }
            return WordTiming(text: word.text, startFrame: f.start, endFrame: f.end, aligned: word.aligned)
        }
        .sorted { ($0.startFrame, $0.endFrame) < ($1.startFrame, $1.endFrame) }
    }

    static func spokenWordCount(in clip: Clip, result: TranscriptionResult, fps: Int) -> Int {
        let visible = sourceSpan(for: clip)
        let rate = Double(fps)
        return result.words.reduce(0) { count, word in
            guard let start = word.start, let end = word.end else { return count }
            let midFrame = (start + end) / 2 * rate
            return visible.start <= midFrame && midFrame < visible.end ? count + 1 : count
        }
    }

    static func phrases(
        for clip: Clip,
        result: TranscriptionResult,
        fps: Int,
        maxWords: Int?,
        minDuration: Double,
        fits: (String) -> Bool,
        segmentation: CaptionBuilder.Segmentation = .default,
        protectedPhrases: [String] = [],
        punctuation: CaptionText.PunctuationPolicy = .keep
    ) -> [CaptionBuilder.Phrase] {
        let hasWordTimings = result.words.contains { $0.start != nil && $0.end != nil }
        let source = sourceSpan(for: clip)
        let rate = Double(fps)
        guard rate > 0 else { return [] }
        let visibleStart = source.start / rate
        let visibleEnd = source.end / rate
        guard visibleEnd > visibleStart else { return [] }

        if hasWordTimings {
            // Prefer word timings so phrase boundaries survive clipped/reordered source fragments.
            return phrasesWithWordTimings(
                visibleStart: visibleStart,
                visibleEnd: visibleEnd,
                result: result,
                maxWords: maxWords,
                minDuration: minDuration,
                fits: fits,
                segmentation: segmentation,
                protectedPhrases: protectedPhrases,
                punctuation: punctuation
            )
        }

        return result.segments.flatMap { segment in
            guard let clipped = clippedSegment(segment, visibleStart: visibleStart, visibleEnd: visibleEnd) else { return [CaptionBuilder.Phrase]() }
            return CaptionBuilder.phrases(
                for: clipped,
                fits: fits,
                maxWords: maxWords,
                minDuration: minDuration,
                segmentation: segmentation,
                protectedPhrases: protectedPhrases,
                punctuation: punctuation
            )
        }
    }

    private static func phrasesWithWordTimings(
        visibleStart: Double,
        visibleEnd: Double,
        result: TranscriptionResult,
        maxWords: Int?,
        minDuration: Double,
        fits: (String) -> Bool,
        segmentation: CaptionBuilder.Segmentation,
        protectedPhrases: [String],
        punctuation: CaptionText.PunctuationPolicy = .keep
    ) -> [CaptionBuilder.Phrase] {
        let segments = result.segments.isEmpty ? [fallbackSegment(for: result)] : result.segments
        var phrases: [CaptionBuilder.Phrase] = []
        var wordIndex = 0

        for segment in segments {
            while wordIndex < result.words.count {
                guard let start = result.words[wordIndex].start, let end = result.words[wordIndex].end else {
                    wordIndex += 1
                    continue
                }
                if (start + end) / 2 < segment.start {
                    wordIndex += 1
                    continue
                }
                break
            }

            var i = wordIndex
            var segmentWords: [TranscriptionWord] = []
            while i < result.words.count {
                let word = result.words[i]
                guard let start = word.start, let end = word.end else {
                    i += 1
                    continue
                }
                let mid = (start + end) / 2
                if mid >= segment.end { break }
                if mid >= segment.start, mid >= visibleStart, mid < visibleEnd {
                    segmentWords.append(word)
                }
                i += 1
            }

            guard !segmentWords.isEmpty else { continue }
            phrases.append(contentsOf: CaptionBuilder.phrases(
                fromTimedWords: segmentWords,
                fits: fits,
                maxWords: maxWords,
                minDuration: minDuration,
                segmentation: segmentation,
                protectedPhrases: protectedPhrases,
                punctuation: punctuation
            ))
        }
        return phrases
    }

    private static func fallbackSegment(for result: TranscriptionResult) -> TranscriptionSegment {
        let timed = result.words.compactMap { word -> (start: Double, end: Double)? in
            guard let start = word.start, let end = word.end else { return nil }
            return (start, end)
        }
        let start = timed.map(\.start).min() ?? 0
        let end = timed.map(\.end).max() ?? start
        return TranscriptionSegment(text: result.text, start: start, end: end)
    }

    private static func clippedSegment(_ segment: TranscriptionSegment, visibleStart: Double, visibleEnd: Double) -> TranscriptionSegment? {
        let start = max(segment.start, visibleStart)
        let end = min(segment.end, visibleEnd)
        guard end > start else { return nil }
        return TranscriptionSegment(text: segment.text, start: start, end: end, speaker: segment.speaker)
    }
}
