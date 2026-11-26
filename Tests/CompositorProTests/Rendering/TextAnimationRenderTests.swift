import CoreImage
import Foundation
import Testing
@testable import CompositorPro

@Suite("TextFrameRenderer — animation")
struct TextAnimationRenderTests {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let size = CGSize(width: 640, height: 360)

    private func clip(_ anim: TextAnimation) -> Clip {
        var c = Clip(mediaRef: "", startFrame: 0, durationFrames: 90)
        c.id = "anim"
        c.mediaType = .text
        c.textContent = "ONE TWO THREE"
        var style = TextStyle()
        style.color = .init(r: 1, g: 1, b: 1, a: 1)
        style.shadow.enabled = false
        style.fontScale = 1.6
        c.textStyle = style
        c.transform = Transform(centerX: 0.5, centerY: 0.5, width: 0.9, height: 0.2)
        c.textAnimation = anim
        c.wordTimings = [
            WordTiming(text: "ONE", startFrame: 0, endFrame: 30),
            WordTiming(text: "TWO", startFrame: 30, endFrame: 60),
            WordTiming(text: "THREE", startFrame: 60, endFrame: 90),
        ]
        return c
    }

    private func pixels(_ clip: Clip, frame: Int, gray: Double = 0) -> [UInt8] {
        guard let text = TextFrameRenderer.image(clip: clip, frame: frame, renderSize: size) else { return [] }
        let bg = CIImage(color: CIColor(red: gray, green: gray, blue: gray)).cropped(to: CGRect(origin: .zero, size: size))
        let out = text.unpremultiplyingAlpha().composited(over: bg)
        let w = Int(size.width), h = Int(size.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        ctx.render(out, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: nil)
        return px
    }

    private func brightCount(_ px: [UInt8]) -> Int {
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4) where Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) > 600 { n += 1 }
        return n
    }

    private func highlightAmount(
        _ preset: TextAnimation.Preset,
        word: WordTiming,
        nextWord: WordTiming?,
        frame: Int
    ) -> Double {
        let animation = TextAnimation(
            preset: preset,
            perWordFrames: 6,
            highlight: .init(r: 1, g: 0, b: 0, a: 1)
        )
        let state = TextAnimator.wordState(
            animation,
            word: word,
            nextWord: nextWord,
            rel: frame,
            base: .init(r: 0, g: 0, b: 0, a: 1)
        )
        return preset == .highlightBlock ? state.bgColor?.a ?? 0 : state.color.r
    }

    @Test func highlightPopColorsActiveWord() {
        let c = clip(TextAnimation(preset: .highlightPop, perWordFrames: 6, highlight: .init(r: 1, g: 0.85, b: 0, a: 1)))
        let mid = pixels(c, frame: 45)  // TWO active → some yellow
        #expect(brightCount(pixels(c, frame: 5)) > 0)   // all words visible
        var yellow = 0
        for i in stride(from: 0, to: mid.count, by: 4)
        where mid[i] > 180 && mid[i + 1] > 150 && mid[i + 2] < 90 { yellow += 1 }
        #expect(yellow > 20, "active word should be highlighted yellow (\(yellow))")
    }

    @Test(arguments: [TextAnimation.Preset.highlightPop, .highlightBlock])
    func shortWordHighlightAttackUsesOriginalTiming(preset: TextAnimation.Preset) {
        let word = WordTiming(text: "A", startFrame: 10, endFrame: 12)
        let nextWord = WordTiming(text: "pause", startFrame: 30, endFrame: 40)

        #expect(highlightAmount(preset, word: word, nextWord: nextWord, frame: 11) == 1)
    }

    @Test(arguments: [TextAnimation.Preset.highlightPop, .highlightBlock])
    func highlightHoldsAcrossPause(preset: TextAnimation.Preset) {
        let word = WordTiming(text: "hold", startFrame: 0, endFrame: 2)
        let nextWord = WordTiming(text: "next", startFrame: 20, endFrame: 30)

        #expect(highlightAmount(preset, word: word, nextWord: nextWord, frame: 15) == 1)
    }

    @Test(arguments: [TextAnimation.Preset.highlightPop, .highlightBlock])
    func adjacentWordHighlightsCrossfadeWithoutGap(preset: TextAnimation.Preset) {
        let word = WordTiming(text: "first", startFrame: 0, endFrame: 2)
        let nextWord = WordTiming(text: "next", startFrame: 20, endFrame: 30)

        for frame in 20...24 {
            let outgoing = highlightAmount(preset, word: word, nextWord: nextWord, frame: frame)
            let incoming = highlightAmount(preset, word: nextWord, nextWord: nil, frame: frame)
            #expect(abs(outgoing + incoming - 1) < 0.000_001)
        }
    }

    @Test(arguments: [TextAnimation.Preset.highlightPop, .highlightBlock])
    func finalWordHighlightHolds(preset: TextAnimation.Preset) {
        let word = WordTiming(text: "final", startFrame: 70, endFrame: 72)

        #expect(highlightAmount(preset, word: word, nextWord: nil, frame: 89) == 1)
    }

    @Test func typewriterShowsCompleteTextOnFinalFrame() {
        var animated = clip(TextAnimation(preset: .typewriter))
        animated.textStyle?.alignment = .left
        var expected = animated
        expected.textAnimation = nil

        let actualPixels = pixels(animated, frame: animated.endFrame - 1)
        let expectedPixels = pixels(expected, frame: expected.endFrame - 1)
        #expect(actualPixels == expectedPixels)
    }

    @Test func typewriterHoldsCompleteTextBeforeClipEnds() {
        var animated = clip(TextAnimation(preset: .typewriter))
        animated.textStyle?.alignment = .left
        var expected = animated
        expected.textAnimation = nil

        let actualPixels = pixels(animated, frame: animated.endFrame - 15)
        let expectedPixels = pixels(expected, frame: expected.endFrame - 15)
        #expect(actualPixels == expectedPixels)
    }

    @Test func typewriterPreviewTypesFinalTokenBeforeHold() {
        var animated = clip(TextAnimation(preset: .typewriter))
        animated.durationFrames = 54
        animated.textContent = "Aa Bb Cc"
        animated.textStyle?.alignment = .left
        animated.wordTimings = nil
        var expected = animated
        expected.textAnimation = nil
        expected.textContent = "Aa Bb |"

        let actualPixels = pixels(animated, frame: 36)
        let expectedPixels = pixels(expected, frame: 36)
        #expect(actualPixels == expectedPixels)
    }

    @Test func laterWordOutlinesDoNotPaintOverEarlierFills() {
        var animated = clip(TextAnimation(preset: .wordReveal, perWordFrames: 4, highlight: .init(r: 1, g: 1, b: 1, a: 1)))
        animated.textStyle?.border = .init(enabled: true, color: .init(r: 1, g: 0, b: 0, a: 1), width: 40)
        animated.textStyle?.tracking = -6
        var expected = animated
        expected.textAnimation = nil

        // Steady frame: all words revealed, no motion — per-word must match static stacking.
        let animatedWhite = brightCount(pixels(animated, frame: 85))
        let staticWhite = brightCount(pixels(expected, frame: 85))
        #expect(staticWhite > 500, "expected a visible white fill baseline")
        #expect(
            animatedWhite >= staticWhite * 97 / 100,
            "later words' outlines must not cover earlier fills (\(animatedWhite) vs \(staticWhite) white pixels)"
        )
    }

    @Test(arguments: [0, 29, 30, 59, 60, 89])
    func singleWordSwitchesAtWordStarts(frame: Int) {
        let animated = clip(TextAnimation(preset: .singleWord))
        var expected = animated
        expected.textAnimation = nil
        expected.textContent = ["ONE", "TWO", "THREE"][frame / 30]

        let expectedPixels = pixels(expected, frame: frame)
        #expect(brightCount(expectedPixels) > 0)
        #expect(pixels(animated, frame: frame) == expectedPixels)
    }

    @Test func singleWordUsesClipRelativeTimingAndLeavesGapsBlank() {
        var animated = clip(TextAnimation(preset: .singleWord))
        animated.startFrame = 100
        animated.wordTimings = [
            .init(text: "ONE", startFrame: 5, endFrame: 20),
            .init(text: "TWO", startFrame: 35, endFrame: 50),
            .init(text: "THREE", startFrame: 65, endFrame: 75),
        ]
        for frame in [100, 104, 120, 134, 150, 164] {
            #expect(brightCount(pixels(animated, frame: frame)) == 0)
        }
        for (frame, word) in [(105, "ONE"), (119, "ONE"), (135, "TWO"), (165, "THREE"), (189, "THREE")] {
            var expected = animated
            expected.textAnimation = nil
            expected.textContent = word
            #expect(pixels(animated, frame: frame) == pixels(expected, frame: frame))
        }
    }

    @Test func singleWordUsesCorrectedDisplayTokensWhenTranscriptCountsDiffer() {
        var animated = clip(TextAnimation(preset: .singleWord))
        animated.textContent = "New York!"
        animated.textStyle?.fontCase = .uppercase
        animated.wordTimings = [.init(text: "New York", startFrame: 10, endFrame: 50)]
        for (frame, word) in [(10, "NEW"), (29, "NEW"), (30, "YORK!"), (89, "YORK!")] {
            var expected = animated
            expected.textAnimation = nil
            expected.textContent = word
            #expect(pixels(animated, frame: frame) == pixels(expected, frame: frame))
        }
    }

    @Test func singleWordFallsBackToEvenTimingForMissingOrUnalignedTranscript() {
        let variants: [[WordTiming]?] = [nil, [.init(text: "unrelated", startFrame: 5, endFrame: 10)]]
        for timings in variants {
            var animated = clip(TextAnimation(preset: .singleWord))
            animated.wordTimings = timings
            for (frame, word) in [(0, "ONE"), (30, "TWO"), (60, "THREE")] {
                var expected = animated
                expected.textAnimation = nil
                expected.textContent = word
                #expect(pixels(animated, frame: frame) == pixels(expected, frame: frame))
            }
        }
    }

    @Test func singleWordMergesTranscriptTokensForCorrectedDisplayContent() {
        var animated = clip(TextAnimation(preset: .singleWord))
        animated.textContent = "NewYork"
        animated.wordTimings = [
            .init(text: "New", startFrame: 10, endFrame: 30),
            .init(text: "York", startFrame: 30, endFrame: 50),
        ]
        var expected = animated
        expected.textAnimation = nil
        for frame in [10, 29, 30, 50, 89] {
            #expect(pixels(animated, frame: frame) == pixels(expected, frame: frame))
        }
    }

    @Test func singleWordDoesNotDisplayCollapsedOrOutOfClipSpans() {
        var animated = clip(TextAnimation(preset: .singleWord))
        animated.textContent = "ONE"
        animated.wordTimings = [.init(text: "ONE", startFrame: 40, endFrame: 40)]
        for frame in [0, 40, 89] {
            #expect(brightCount(pixels(animated, frame: frame)) == 0)
        }
        #expect(TextFrameRenderer.image(clip: animated, frame: -1, renderSize: size) == nil)
        #expect(TextFrameRenderer.image(clip: animated, frame: 90, renderSize: size) == nil)
    }

    @Test func singleWordCentersEachTokenWithTheExistingBoxAndStyle() {
        var animated = clip(TextAnimation(preset: .singleWord))
        animated.textStyle?.alignment = .left
        animated.textStyle?.border = .init(enabled: true, color: .init(r: 1, g: 0, b: 0, a: 1), width: 6)
        animated.textStyle?.background.enabled = true
        var expected = animated
        expected.textAnimation = nil
        expected.textStyle?.alignment = .center
        expected.textContent = "TWO"

        #expect(pixels(animated, frame: 45) == pixels(expected, frame: 45))
    }

    @Test func tokenTimingsSplitAlignedTranscriptSpan() {
        let tokens = [
            (range: NSRange(location: 0, length: 3), text: "New"),
            (range: NSRange(location: 4, length: 4), text: "York"),
        ]

        let timings = TextFrameRenderer.tokenTimings(
            tokens,
            [WordTiming(text: "New York", startFrame: 10, endFrame: 50)],
            duration: 90
        )

        #expect(timings == [
            WordTiming(text: "New", startFrame: 10, endFrame: 30),
            WordTiming(text: "York", startFrame: 30, endFrame: 50),
        ])
    }

    @Test func tokenTimingsMergeAlignedTranscriptSpans() {
        let tokens = [
            (range: NSRange(location: 0, length: 7), text: "NewYork"),
        ]

        let timings = TextFrameRenderer.tokenTimings(
            tokens,
            [
                WordTiming(text: "New", startFrame: 10, endFrame: 30),
                WordTiming(text: "York", startFrame: 30, endFrame: 50),
            ],
            duration: 90
        )

        #expect(timings == [
            WordTiming(text: "NewYork", startFrame: 10, endFrame: 50),
        ])
    }
}
