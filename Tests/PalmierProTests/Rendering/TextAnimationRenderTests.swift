import CoreImage
import Foundation
import Testing
@testable import PalmierPro

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

    @Test func wordPopRevealsProgressively() {
        let c = clip(TextAnimation(preset: .wordPop, perWordFrames: 6))
        let early = pixels(c, frame: 5)   // only ONE has started
        let late = pixels(c, frame: 80)   // all three in
        #expect(brightCount(early) > 0, "first word should be visible early")
        #expect(brightCount(late) > brightCount(early) * 2, "more words visible later (\(brightCount(early)) → \(brightCount(late)))")
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
