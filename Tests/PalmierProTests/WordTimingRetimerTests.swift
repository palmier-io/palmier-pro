import Foundation
import Testing
@testable import PalmierPro

@Suite("WordTimingRetimer")
struct WordTimingRetimerTests {
    private func span(_ text: String, _ start: Int, _ end: Int, aligned: Bool? = true) -> WordTiming {
        WordTiming(text: text, startFrame: start, endFrame: end, aligned: aligned)
    }

    @Test func removingLeadingPunctuationKeepsExactSpans() {
        let old = [
            span("，", 0, 0, aligned: nil),
            span("我", 0, 10), span("肯", 10, 20), span("定", 20, 30),
        ]
        let retimed = WordTimingRetimer.retime(old: old, newContent: "我肯定", duration: 30)
        #expect(retimed == [span("我", 0, 10), span("肯", 10, 20), span("定", 20, 30)])
    }

    @Test func deletingMiddleWordLeavesNeighboursUnshifted() {
        let old = [span("我", 0, 10), span("呃", 10, 20), span("好", 20, 30)]
        let retimed = WordTimingRetimer.retime(old: old, newContent: "我好", duration: 30)
        // 好 keeps its exact old start (20) — the deleted filler's time is absorbed as a gap.
        #expect(retimed == [span("我", 0, 10), span("好", 20, 30)])
    }

    @Test func replacingOneWordInterpolatesOnlyThatWord() {
        let old = [span("the", 0, 10), span("quick", 10, 40), span("fox", 40, 60)]
        let retimed = WordTimingRetimer.retime(old: old, newContent: "the slow fox", duration: 60)!
        #expect(retimed[0] == span("the", 0, 10), "unchanged word keeps its exact span")
        #expect(retimed[2] == span("fox", 40, 60), "unchanged word keeps its exact span")
        #expect(retimed[1].text == "slow")
        #expect(retimed[1].aligned == false, "replaced word is marked interpolated")
        #expect(retimed[1].startFrame >= 10 && retimed[1].endFrame <= 40, "interpolated within the neighbours' gap")
    }

    @Test func insertingWordsInterpolatesWithinGap() {
        let old = [span("hello", 0, 30), span("world", 30, 60)]
        let retimed = WordTimingRetimer.retime(old: old, newContent: "hello brave new world", duration: 60)!
        #expect(retimed.map(\.text) == ["hello", "brave", "new", "world"])
        #expect(retimed.first == span("hello", 0, 30))
        #expect(retimed.last == span("world", 30, 60))
        #expect(retimed[1].aligned == false && retimed[2].aligned == false)
        #expect(retimed[1].startFrame >= 30 && retimed[2].endFrame <= 30, "inserted run sits between the anchors")
    }

    @Test func fullRewriteWithNoAnchorReturnsNil() {
        let old = [span("the", 0, 10), span("quick", 10, 40), span("fox", 40, 60)]
        #expect(WordTimingRetimer.retime(old: old, newContent: "完全不同", duration: 60) == nil)
    }

    @Test func setCaptionContentRetimesInPlace() {
        var clip = Clip(mediaRef: "", startFrame: 0, durationFrames: 30)
        clip.mediaType = .text
        clip.textContent = "我呃好"
        clip.wordTimings = [span("我", 0, 10), span("呃", 10, 20), span("好", 20, 30)]

        let cleared = clip.setCaptionContent("我好")
        #expect(cleared == false, "a partial edit does not clear timings")
        #expect(clip.wordTimings == [span("我", 0, 10), span("好", 20, 30)])
        #expect(clip.textContent == "我好")
    }

    @Test func setCaptionContentClearsOnFullRewrite() {
        var clip = Clip(mediaRef: "", startFrame: 0, durationFrames: 30)
        clip.mediaType = .text
        clip.textContent = "the quick fox"
        clip.wordTimings = [span("the", 0, 10), span("quick", 10, 20), span("fox", 20, 30)]

        let cleared = clip.setCaptionContent("完全不同的一句话")
        #expect(cleared == true, "a rewrite with no surviving word clears timings")
        #expect(clip.wordTimings == nil)
    }

    @Test func unchangedContentLeavesTimingsUntouched() {
        var clip = Clip(mediaRef: "", startFrame: 0, durationFrames: 30)
        clip.mediaType = .text
        clip.textContent = "hello world"
        let original: [WordTiming] = [span("hello", 0, 15), span("world", 15, 30)]
        clip.wordTimings = original

        let cleared = clip.setCaptionContent("hello world")
        #expect(cleared == false)
        #expect(clip.wordTimings == original, "a style-only / no-op content set never touches timings")
    }
}
