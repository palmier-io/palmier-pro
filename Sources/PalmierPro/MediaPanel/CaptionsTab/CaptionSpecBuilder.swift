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
                minDuration: AppTheme.Caption.minDisplayDuration,
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
        return closingShortGaps(
            in: specs,
            settings: input.gapSettings,
            fps: input.fps
        )
    }

    private static func closingShortGaps(
        in specs: [EditorViewModel.TextClipSpec],
        settings: CaptionGapSettings,
        fps: Int
    ) -> [EditorViewModel.TextClipSpec] {
        let maximumGapFrames = settings.maximumGapFrames(fps: fps)
        guard maximumGapFrames > 0, !specs.isEmpty else { return specs }

        var adjusted = specs
        let ordered = adjusted.indices.sorted {
            let lhs = adjusted[$0].startFrame
            let rhs = adjusted[$1].startFrame
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
        guard let firstIndex = ordered.first else { return adjusted }
        var coverageIndex = firstIndex
        let (firstEnd, firstEndOverflow) = adjusted[firstIndex].startFrame.addingReportingOverflow(
            adjusted[firstIndex].durationFrames
        )
        var coverageEnd = firstEndOverflow ? adjusted[firstIndex].startFrame : firstEnd

        for nextIndex in ordered.dropFirst() {
            let next = adjusted[nextIndex]
            if next.startFrame > coverageEnd {
                let (gap, gapOverflow) = next.startFrame.subtractingReportingOverflow(coverageEnd)
                if !gapOverflow, gap <= maximumGapFrames {
                    let overlapFrames = next.animation?.preset.needsIncomingCaptionCoverage == true ? 1 : 0
                    let (closedEnd, endOverflow) = next.startFrame.addingReportingOverflow(
                        overlapFrames
                    )
                    let previousStart = adjusted[coverageIndex].startFrame
                    let (duration, durationOverflow) = closedEnd.subtractingReportingOverflow(
                        previousStart
                    )
                    if !endOverflow, !durationOverflow, duration > 0 {
                        var previous = adjusted[coverageIndex]
                        previous.durationFrames = duration
                        if previous.animation?.preset == .wordCycle,
                           var words = previous.words,
                           let lastIndex = words.indices.last {
                            words[lastIndex].endFrame = duration
                            previous.words = words
                        }
                        adjusted[coverageIndex] = previous
                        coverageEnd = closedEnd
                    }
                }
            }

            let (nextEnd, nextEndOverflow) = next.startFrame.addingReportingOverflow(
                next.durationFrames
            )
            if !nextEndOverflow, nextEnd >= coverageEnd {
                coverageEnd = max(coverageEnd, nextEnd)
                coverageIndex = nextIndex
            }
        }
        return adjusted
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
