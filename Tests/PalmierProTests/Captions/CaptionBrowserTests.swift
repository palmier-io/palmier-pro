import Testing
@testable import PalmierPro

@Suite struct CaptionBrowserTests {
    private func caption(_ id: String, text: String, start: Int) -> Clip {
        var clip = Fixtures.clip(
            id: id,
            mediaRef: "text",
            mediaType: .text,
            start: start,
            duration: 10
        )
        clip.textContent = text
        clip.captionGroupId = "captions"
        return clip
    }

    @Test func calculatesCharactersPerSecondFromTimelineDuration() {
        let cps = CaptionBrowserMetrics.charactersPerSecond(
            content: "12345 6789",
            durationFrames: 30,
            fps: 30
        )

        #expect(cps == 10)
    }

    @Test func excludesLineBreaksFromCharacterCount() {
        let cps = CaptionBrowserMetrics.charactersPerSecond(
            content: "12345\n6789",
            durationFrames: 30,
            fps: 30
        )

        #expect(cps == 9)
    }

    @Test(arguments: [
        (durationFrames: 0, fps: 30),
        (durationFrames: 30, fps: 0),
    ])
    func rejectsInvalidTiming(durationFrames: Int, fps: Int) {
        #expect(CaptionBrowserMetrics.charactersPerSecond(
            content: "Caption",
            durationFrames: durationFrames,
            fps: fps
        ) == nil)
    }

    @Test func collectsOnlyCaptionTextInTimelineOrder() {
        let first = caption("first", text: "First", start: 0)
        let sameStartFirst = caption("a", text: "Same start first", start: 10)
        let sameStartSecond = caption("b", text: "Same start second", start: 10)
        var plainText = caption("plain", text: "Plain text", start: 5)
        plainText.captionGroupId = nil
        var groupedVideo = caption("video", text: "Video", start: 5)
        groupedVideo.mediaType = .video
        let timeline = Timeline(
            tracks: [Track(
                type: .video,
                clips: [sameStartSecond, plainText, first, groupedVideo, sameStartFirst]
            )]
        )

        let captions = CaptionBrowserNavigation.sortedCaptions(in: timeline)

        #expect(captions.map(\.id) == ["first", "a", "b"])
    }

    @Test func searchMatchesCaptionTextCaseInsensitivelyAndKeepsTimelineNumbers() {
        let captions = [
            caption("first", text: "Opening line", start: 0),
            caption("second", text: "A HIDDEN feature", start: 10),
            caption("third", text: "Another hidden detail", start: 20),
        ]

        let matches = CaptionBrowserNavigation.numberedCaptions(
            captions,
            matching: " hidden "
        )

        #expect(matches.map { $0.clip.id } == ["second", "third"])
        #expect(matches.map(\.number) == [2, 3])
    }

    @Test func currentCaptionUsesHalfOpenTimelineRanges() {
        let captions = [
            caption("first", text: "First", start: 0),
            caption("second", text: "Second", start: 10),
        ]

        #expect(CaptionBrowserNavigation.currentCaption(in: captions, at: -1) == nil)
        #expect(CaptionBrowserNavigation.currentCaption(in: captions, at: 0)?.id == "first")
        #expect(CaptionBrowserNavigation.currentCaption(in: captions, at: 9)?.id == "first")
        #expect(CaptionBrowserNavigation.currentCaption(in: captions, at: 10)?.id == "second")
        #expect(CaptionBrowserNavigation.currentCaption(in: captions, at: 19)?.id == "second")
        #expect(CaptionBrowserNavigation.currentCaption(in: captions, at: 20) == nil)
    }
}
