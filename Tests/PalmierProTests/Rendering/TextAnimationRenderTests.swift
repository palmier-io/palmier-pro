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

    @Test func wordTimingAlignedRoundTripsCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for aligned in [true, false, nil] as [Bool?] {
            let w = WordTiming(text: "hi", startFrame: 1, endFrame: 2, aligned: aligned)
            #expect(try decoder.decode(WordTiming.self, from: encoder.encode(w)) == w)
        }
        // Old projects have no `aligned` key — they must still decode (to nil).
        let legacy = Data(#"{"text":"hi","startFrame":1,"endFrame":2}"#.utf8)
        let decoded = try decoder.decode(WordTiming.self, from: legacy)
        #expect(decoded.aligned == nil)
        #expect(decoded == WordTiming(text: "hi", startFrame: 1, endFrame: 2))
    }

    /// A space-less CJK line with non-uniform per-character timings: the middle gap must NOT be
    /// highlighted (per-character spans drive the animation, not one collapsed line span).
    @Test func cjkHighlightHonoursPerCharacterSpans() {
        var c = Clip(mediaRef: "", startFrame: 0, durationFrames: 90)
        c.id = "cjk"
        c.mediaType = .text
        c.textContent = "我好"
        var style = TextStyle()
        style.color = .init(r: 1, g: 1, b: 1, a: 1)
        style.shadow.enabled = false
        style.fontScale = 1.6
        c.textStyle = style
        c.transform = Transform(centerX: 0.5, centerY: 0.5, width: 0.9, height: 0.3)
        c.textAnimation = TextAnimation(preset: .highlightPop, perWordFrames: 6, highlight: .init(r: 1, g: 0.85, b: 0, a: 1))
        c.wordTimings = [
            WordTiming(text: "我", startFrame: 0, endFrame: 15, aligned: true),
            WordTiming(text: "好", startFrame: 75, endFrame: 90, aligned: true),
        ]

        func yellow(_ frame: Int) -> Int {
            let px = pixels(c, frame: frame)
            var n = 0
            for i in stride(from: 0, to: px.count, by: 4)
            where px[i] > 180 && px[i + 1] > 150 && px[i + 2] < 90 { n += 1 }
            return n
        }

        #expect(yellow(5) > 0, "first character highlighted while it is active")
        #expect(yellow(82) > 0, "last character highlighted while it is active")
        #expect(yellow(45) == 0, "the silent gap between characters is never highlighted")
    }

    // MARK: - Granularity (word default vs. per-character opt-in)

    private func unitTexts(_ content: String, _ g: TextAnimation.Granularity) -> [String] {
        TextFrameRenderer.animationUnits(in: content, granularity: g).map(\.text)
    }

    @Test func wordModeGroupsCJKIntoNLTokenizerUnits() {
        // Default (word) groups a space-less CJK run into NLTokenizer words, not per character.
        #expect(unitTexts("电影照片", .word) == ["电影", "照片"])
    }

    @Test func charModeReproducesPerCharacter() {
        #expect(unitTexts("电影照片", .char) == ["电", "影", "照", "片"])
    }

    @Test func wordModeUnionsPerCharacterSpans() {
        // Per-character transcript timings must collapse into one span per NLTokenizer word.
        let units = TextFrameRenderer.animationUnits(in: "电影照片", granularity: .word)
        let perChar = [
            WordTiming(text: "电", startFrame: 10, endFrame: 20),
            WordTiming(text: "影", startFrame: 20, endFrame: 35),
            WordTiming(text: "照", startFrame: 50, endFrame: 60),
            WordTiming(text: "片", startFrame: 60, endFrame: 80),
        ]
        let timings = TextFrameRenderer.tokenTimings(units, perChar, duration: 90)
        #expect(timings == [
            WordTiming(text: "电影", startFrame: 10, endFrame: 35),
            WordTiming(text: "照片", startFrame: 50, endFrame: 80),
        ])
    }

    @Test func latinUnaffectedByWordMode() {
        // Latin whitespace runs are identical in both modes, and punctuation-glued runs stay whole.
        #expect(unitTexts("New York", .word) == ["New", "York"])
        #expect(unitTexts("New York", .char) == ["New", "York"])
        #expect(unitTexts("U.S. flag", .word) == ["U.S.", "flag"])
    }

    @Test func nilWordTimingsUniformFallbackPerWordUnit() {
        // No transcript timings → each word unit gets an even slice of the duration (word-mode units).
        let units = TextFrameRenderer.animationUnits(in: "电影照片", granularity: .word)
        let timings = TextFrameRenderer.tokenTimings(units, nil, duration: 90)
        #expect(timings == [
            WordTiming(text: "电影", startFrame: 0, endFrame: 45),
            WordTiming(text: "照片", startFrame: 45, endFrame: 90),
        ])
    }

    @Test func granularityMissingFieldDecodesToWord() throws {
        // Old projects (and the recent per-char default) have no granularity key → word.
        let legacy = Data(#"{"preset":"highlightPop","perWordFrames":6}"#.utf8)
        let decoded = try JSONDecoder().decode(TextAnimation.self, from: legacy)
        #expect(decoded.granularity == .word)
    }

    @Test func granularityRoundTripsCodable() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        for g in [TextAnimation.Granularity.word, .char] {
            let a = TextAnimation(preset: .highlightPop, granularity: g)
            #expect(try decoder.decode(TextAnimation.self, from: encoder.encode(a)).granularity == g)
        }
    }

    @Test func noWordTimingsStillAnimatesUniformly() {
        var c = Clip(mediaRef: "", startFrame: 0, durationFrames: 90)
        c.id = "uniform"
        c.mediaType = .text
        c.textContent = "ONE TWO THREE"
        var style = TextStyle()
        style.color = .init(r: 1, g: 1, b: 1, a: 1)
        style.shadow.enabled = false
        style.fontScale = 1.6
        c.textStyle = style
        c.transform = Transform(centerX: 0.5, centerY: 0.5, width: 0.9, height: 0.2)
        c.textAnimation = TextAnimation(preset: .wordPop, perWordFrames: 6)
        c.wordTimings = nil

        #expect(brightCount(pixels(c, frame: 5)) > 0, "uniform fallback still reveals words")
        #expect(brightCount(pixels(c, frame: 80)) > brightCount(pixels(c, frame: 5)))
    }
}
