import Testing
@testable import PalmierPro

@Suite struct CaptionIndexTests {
    private func caption(
        _ id: String,
        text: String,
        start: Int,
        duration: Int = 10,
        groupId: String = "captions"
    ) -> Clip {
        var clip = Fixtures.clip(
            id: id,
            mediaRef: "text",
            mediaType: .text,
            start: start,
            duration: duration
        )
        clip.textContent = text
        clip.captionGroupId = groupId
        return clip
    }

    @Test func formatsDurationToOneDecimalSecond() {
        #expect(CaptionBrowserMetrics.durationLabel(durationFrames: 30, fps: 30) == "1.0s")
        #expect(CaptionBrowserMetrics.durationLabel(durationFrames: 45, fps: 30) == "1.5s")
        #expect(CaptionBrowserMetrics.durationLabel(durationFrames: 10, fps: 30) == "0.3s")
    }

    @Test(arguments: [
        (durationFrames: 0, fps: 30),
        (durationFrames: 30, fps: 0),
    ])
    func rejectsInvalidDuration(durationFrames: Int, fps: Int) {
        #expect(CaptionBrowserMetrics.durationLabel(
            durationFrames: durationFrames,
            fps: fps
        ) == nil)
    }

    @Test func groupsCaptionTextByTopmostTrackAndTimelineOrder() {
        let first = caption("first", text: "First", start: 0, groupId: "top")
        let sameStartFirst = caption("a", text: "Same start first", start: 10, groupId: "top")
        let sameStartSecond = caption("b", text: "Same start second", start: 10, groupId: "top")
        let lower = caption("lower", text: "Lower", start: 5, groupId: "lower")
        var plainText = caption("plain", text: "Plain text", start: 5)
        plainText.captionGroupId = nil
        var groupedVideo = caption("video", text: "Video", start: 5)
        groupedVideo.mediaType = .video
        let timeline = Timeline(tracks: [
            Track(
                type: .video,
                hidden: true,
                clips: [sameStartSecond, plainText, first, groupedVideo, sameStartFirst]
            ),
            Track(type: .video, clips: [lower]),
        ])

        let groups = CaptionBrowserNavigation.groups(in: timeline)

        #expect(groups.map(\.id) == ["top", "lower"])
        #expect(groups.map(\.trackIndex) == [0, 1])
        #expect(groups.map(\.isVisible) == [false, true])
        #expect(groups[0].captions.map(\.id) == ["first", "a", "b"])
        #expect(groups[1].captions.map(\.id) == ["lower"])
    }

    @Test func formatsTrackCodeWithOptionalName() {
        #expect(CaptionBrowserNavigation.groupLabel(code: "V1", name: nil) == "V1")
        #expect(CaptionBrowserNavigation.groupLabel(code: "V1", name: "") == "V1")
        #expect(CaptionBrowserNavigation.groupLabel(code: "V1", name: "test1") == "V1 (test1)")
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
        let index = CaptionBrowserTimelineIndex(sortedCaptions: captions)

        #expect(index.currentCaption(at: -1) == nil)
        #expect(index.currentCaption(at: 0)?.id == "first")
        #expect(index.currentCaption(at: 9)?.id == "first")
        #expect(index.currentCaption(at: 10)?.id == "second")
        #expect(index.currentCaption(at: 19)?.id == "second")
        #expect(index.currentCaption(at: 20) == nil)
    }

    @Test func currentCaptionFallsBackToEarlierOverlappingCaption() {
        let captions = [
            caption("long", text: "Long caption", start: 0, duration: 100),
            caption("short", text: "Short caption", start: 10, duration: 5),
        ]
        let index = CaptionBrowserTimelineIndex(sortedCaptions: captions)

        #expect(index.currentCaption(at: 14)?.id == "short")
        #expect(index.currentCaption(at: 15)?.id == "long")
        #expect(index.currentCaption(at: 99)?.id == "long")
        #expect(index.currentCaption(at: 100) == nil)
    }
}
