import CoreGraphics
import Foundation

enum CaptionSpecBuilder {
    struct Target: Sendable {
        let clip: Clip
        let result: TranscriptionResult
    }

    struct Input: Sendable {
        let targets: [Target]
        let fps: Int
        let canvasWidth: Int
        let canvasHeight: Int
        let style: TextStyle
        let center: CGPoint
        let textCase: EditorViewModel.CaptionCase
        let maxWords: Int?
        let maxCharacters: Int?
        let gapSettings: CaptionGapSettings
        let animation: TextAnimation?
    }

    @concurrent
    static func build(_ input: Input) async throws -> [EditorViewModel.TextClipSpec] {
        try Task.checkCancellation()
        let groupId = UUID().uuidString
        var specs: [EditorViewModel.TextClipSpec] = []

        for target in input.targets {
            try Task.checkCancellation()
            let phrases = CaptionTranscriptMapper.phrases(
                for: target.clip,
                result: target.result,
                fps: input.fps,
                maxWords: input.maxWords,
                maxCharacters: input.maxCharacters,
                fits: { text in
                    if Task.isCancelled { return true }
                    return lineFits(
                        text,
                        style: input.style,
                        canvasWidth: input.canvasWidth,
                        canvasHeight: input.canvasHeight
                    )
                }
            )
            try Task.checkCancellation()
            guard !phrases.isEmpty else { continue }

            let cased = phrases.map {
                CaptionBuilder.Phrase(
                    text: input.textCase.apply($0.text),
                    start: $0.start,
                    end: $0.end,
                    words: $0.words
                )
            }
            specs.append(contentsOf: CaptionBuilder.specs(
                for: cased,
                sourceClip: target.clip,
                trackIndex: 0,
                fps: input.fps,
                style: input.style,
                captionGroupId: groupId,
                animation: input.animation,
                transformFor: { text in
                    guard !Task.isCancelled else { return nil }
                    return transform(
                        for: text,
                        style: input.style,
                        center: input.center,
                        canvasWidth: input.canvasWidth,
                        canvasHeight: input.canvasHeight
                    )
                }
            ))
            try Task.checkCancellation()
        }
        return adjustedCaptionTiming(
            in: specs,
            settings: input.gapSettings,
            fps: input.fps
        )
    }

    private struct TimedCaption {
        var spec: EditorViewModel.TextClipSpec
        let originalDurationFrames: Int
    }

    private static func adjustedCaptionTiming(
        in specs: [EditorViewModel.TextClipSpec],
        settings: CaptionGapSettings,
        fps: Int
    ) -> [EditorViewModel.TextClipSpec] {
        let orderedIndices = specs.indices.sorted {
            let lhsStart = specs[$0].startFrame
            let rhsStart = specs[$1].startFrame
            return lhsStart == rhsStart ? $0 < $1 : lhsStart < rhsStart
        }
        var captions = orderedIndices.map {
            TimedCaption(spec: specs[$0], originalDurationFrames: specs[$0].durationFrames)
        }
        let maximumGapFrames = settings.maximumGapFrames(fps: fps)

        // Resolve collisions before extending captions across eligible gaps.
        for nextIndex in captions.indices.dropFirst() {
            let previousIndex = nextIndex - 1
            var previous = captions[previousIndex]
            var next = captions[nextIndex]
            resolveOverlap(previous: &previous, next: &next)
            captions[previousIndex] = previous
            captions[nextIndex] = next

            if maximumGapFrames > 0,
               let previousEnd = endFrame(of: captions[previousIndex].spec),
               let gap = positiveDistance(from: previousEnd, to: captions[nextIndex].spec.startFrame),
               gap <= maximumGapFrames,
               let duration = positiveDistance(
                   from: captions[previousIndex].spec.startFrame,
                   to: captions[nextIndex].spec.startFrame
               ) {
                captions[previousIndex].spec = resized(
                    captions[previousIndex].spec,
                    durationFrames: duration,
                    extendWordCycle: true
                )
            }
        }
        return captions.map(\.spec)
    }

    private static func resolveOverlap(
        previous: inout TimedCaption,
        next: inout TimedCaption
    ) {
        guard let previousEnd = endFrame(of: previous.spec),
              next.spec.startFrame < previousEnd else { return }

        if next.spec.startFrame <= previous.spec.startFrame {
            // Preserve transcript order when starts quantize to the same frame.
            previous.spec = resized(previous.spec, durationFrames: 1)
            if let shiftedStart = endFrame(of: previous.spec) {
                shiftStartPreservingEnd(&next.spec, to: shiftedStart)
            }
            return
        }

        let overlap = positiveDistance(from: next.spec.startFrame, to: previousEnd)
        if overlap == 1, previous.originalDurationFrames < next.originalDurationFrames {
            // The shorter caption owns a one-frame rounding collision.
            shiftStartPreservingEnd(&next.spec, to: previousEnd)
            return
        }

        // Wider overlaps end at the next caption's authoritative start.
        if let duration = positiveDistance(
            from: previous.spec.startFrame,
            to: next.spec.startFrame
        ) {
            previous.spec = resized(previous.spec, durationFrames: duration)
        }
    }

    private static func endFrame(of spec: EditorViewModel.TextClipSpec) -> Int? {
        let result = spec.startFrame.addingReportingOverflow(spec.durationFrames)
        return result.overflow ? nil : result.partialValue
    }

    private static func positiveDistance(from start: Int, to end: Int) -> Int? {
        let result = end.subtractingReportingOverflow(start)
        return !result.overflow && result.partialValue > 0 ? result.partialValue : nil
    }

    private static func shiftStartPreservingEnd(
        _ spec: inout EditorViewModel.TextClipSpec,
        to startFrame: Int
    ) {
        let wordOffsetFrames = positiveDistance(from: spec.startFrame, to: startFrame) ?? 0
        let originalEnd = endFrame(of: spec)
        spec.startFrame = startFrame
        let durationFrames = originalEnd.flatMap {
            positiveDistance(from: startFrame, to: $0)
        } ?? 1
        spec = resized(
            spec,
            durationFrames: durationFrames,
            wordOffsetFrames: wordOffsetFrames
        )
    }

    private static func resized(
        _ spec: EditorViewModel.TextClipSpec,
        durationFrames: Int,
        wordOffsetFrames: Int = 0,
        extendWordCycle: Bool = false
    ) -> EditorViewModel.TextClipSpec {
        var resized = spec
        resized.durationFrames = durationFrames
        guard let originalWords = resized.words else { return resized }

        var words = originalWords.compactMap { word -> WordTiming? in
            let shiftedStart = word.startFrame.subtractingReportingOverflow(wordOffsetFrames)
            let shiftedEnd = word.endFrame.subtractingReportingOverflow(wordOffsetFrames)
            let start = min(max(0, shiftedStart.overflow ? 0 : shiftedStart.partialValue), durationFrames)
            let end = min(max(start, shiftedEnd.overflow ? 0 : shiftedEnd.partialValue), durationFrames)
            return end > start
                ? WordTiming(text: word.text, startFrame: start, endFrame: end)
                : nil
        }
        if extendWordCycle,
           resized.animation?.preset == .wordCycle,
           let lastIndex = words.indices.last {
            words[lastIndex].endFrame = durationFrames
        }
        resized.words = words.isEmpty ? nil : words
        return resized
    }

    private static func lineFits(
        _ text: String,
        style: TextStyle,
        canvasWidth: Int,
        canvasHeight: Int
    ) -> Bool {
        let size = TextLayout.naturalSize(
            content: text,
            style: style,
            maxWidth: .greatestFiniteMagnitude,
            canvasHeight: CGFloat(canvasHeight)
        )
        return size.width <= CGFloat(canvasWidth) * AppTheme.ComponentSize.captionPreviewMaxTextWidthRatio
    }

    private static func transform(
        for text: String,
        style: TextStyle,
        center: CGPoint,
        canvasWidth: Int,
        canvasHeight: Int
    ) -> Transform {
        let width = Double(canvasWidth)
        let height = Double(canvasHeight)
        let natural = TextLayout.naturalSize(
            content: text,
            style: style,
            maxWidth: CGFloat(width) * AppTheme.ComponentSize.captionPreviewMaxTextWidthRatio,
            canvasHeight: CGFloat(height)
        )
        return Transform(
            center: (Double(center.x), Double(center.y)),
            width: Double(natural.width) / width,
            height: Double(natural.height) / height
        )
    }
}
