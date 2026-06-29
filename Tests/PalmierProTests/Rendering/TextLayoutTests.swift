import Testing
@testable import PalmierPro

@Suite("TextLayout")
struct TextLayoutTests {

    @Test func wordFramesKeepTopToBottomLineOrder() {
        var style = TextStyle()
        style.fontSize = 48
        style.alignment = .center
        let content = "Hello world foo bar"
        let words = [
            CaptionWordTiming(text: "Hello", startFrame: 0, endFrame: 5),
            CaptionWordTiming(text: "world", startFrame: 5, endFrame: 10),
            CaptionWordTiming(text: "foo", startFrame: 10, endFrame: 15),
            CaptionWordTiming(text: "bar", startFrame: 15, endFrame: 20),
        ]
        let box = TextLayout.naturalSize(
            content: content,
            style: style,
            maxWidth: 120,
            canvasHeight: 1080
        )
        let frames = TextLayout.wordFrames(
            content: content,
            words: words,
            style: style,
            boxSize: box,
            canvasHeight: 1080
        )
        #expect(frames.count == 4)
        let firstLine = frames.filter { $0.text == "Hello" || $0.text == "world" }
        let secondLine = frames.filter { $0.text == "foo" || $0.text == "bar" }
        let firstY = firstLine.map(\.rect.origin.y).max() ?? 0
        let secondY = secondLine.map(\.rect.origin.y).min() ?? 0
        #expect(secondY > firstY)
    }

    @Test func wordFramesPairByIndexNotText() {
        var style = TextStyle()
        style.fontSize = 48
        let content = "hello world end"
        let words = [
            CaptionWordTiming(text: "hello,", startFrame: 0, endFrame: 5),
            CaptionWordTiming(text: "world", startFrame: 5, endFrame: 10),
            CaptionWordTiming(text: "end.", startFrame: 10, endFrame: 15),
        ]
        let box = TextLayout.naturalSize(
            content: content, style: style, maxWidth: 1000, canvasHeight: 1080
        )
        let frames = TextLayout.wordFrames(
            content: content, words: words, style: style, boxSize: box, canvasHeight: 1080
        )
        #expect(frames.count == words.count)
        #expect(frames[0].rect.minX < frames[1].rect.minX)
        #expect(frames[1].rect.minX < frames[2].rect.minX)
    }

    @Test func wordFramesShareLineHeightOnSameLine() {
        var style = TextStyle()
        style.fontSize = 48
        let content = "big g"
        let words = [
            CaptionWordTiming(text: "big", startFrame: 0, endFrame: 5),
            CaptionWordTiming(text: "g", startFrame: 5, endFrame: 10),
        ]
        let box = TextLayout.naturalSize(
            content: content, style: style, maxWidth: 400, canvasHeight: 1080
        )
        let frames = TextLayout.wordFrames(
            content: content, words: words, style: style, boxSize: box, canvasHeight: 1080
        )
        #expect(frames.count == 2)
        #expect(frames[0].rect.height == frames[1].rect.height)
        #expect(frames[0].rect.origin.y == frames[1].rect.origin.y)
    }
}
