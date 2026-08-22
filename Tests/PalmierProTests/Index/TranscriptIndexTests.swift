import CoreGraphics
import Testing
@testable import PalmierPro

@Suite struct TranscriptIndexTests {
    private func row(
        _ id: String,
        text: String,
        start: Int,
        duration: Int = 10
    ) -> EditorViewModel.TimelineTranscriptRow {
        EditorViewModel.TimelineTranscriptRow(
            id: id,
            clipId: "source",
            text: text,
            startFrame: start,
            endFrame: start + duration
        )
    }

    @Test func formatsDurationToOneDecimalSecond() {
        #expect(TranscriptBrowserMetrics.durationLabel(durationFrames: 30, fps: 30) == "1.0s")
        #expect(TranscriptBrowserMetrics.durationLabel(durationFrames: 45, fps: 30) == "1.5s")
        #expect(TranscriptBrowserMetrics.durationLabel(durationFrames: 10, fps: 30) == "0.3s")
    }

    @Test(arguments: [
        (durationFrames: 0, fps: 30),
        (durationFrames: 30, fps: 0),
    ])
    func rejectsInvalidDuration(durationFrames: Int, fps: Int) {
        #expect(TranscriptBrowserMetrics.durationLabel(
            durationFrames: durationFrames,
            fps: fps
        ) == nil)
    }

    @Test func captionGroupProvidesFallbackRowsWithoutAudioTranscript() throws {
        var second = Fixtures.clip(
            id: "second",
            mediaRef: "text",
            mediaType: .text,
            start: 30,
            duration: 20
        )
        second.textContent = "Second cue"
        second.captionGroupId = "imported-vtt"
        var first = Fixtures.clip(
            id: "first",
            mediaRef: "text",
            mediaType: .text,
            start: 0,
            duration: 20
        )
        first.textContent = "First cue"
        first.captionGroupId = "imported-vtt"
        var translated = Fixtures.clip(
            id: "translated",
            mediaRef: "text",
            mediaType: .text,
            start: 0,
            duration: 20
        )
        translated.textContent = "Premier sous-titre"
        translated.captionGroupId = "translated-vtt"
        let timeline = Fixtures.timeline(
            tracks: [
                Fixtures.videoTrack(clips: [second, first]),
                Fixtures.videoTrack(clips: [translated]),
            ]
        )

        let fallbacks = TranscriptBrowserNavigation.captionFallbacks(in: timeline)
        let fallback = try #require(fallbacks.first)

        #expect(fallbacks.map(\.sourceCaptionGroupId) == ["imported-vtt", "translated-vtt"])
        #expect(fallback.sourceTrackId == timeline.tracks[0].id)
        #expect(fallback.sourceCaptionGroupId == "imported-vtt")
        #expect(fallback.rows.map(\.text) == ["First cue", "Second cue"])
    }

    @Test func searchMatchesTranscriptTextCaseInsensitively() {
        let rows = [
            row("first", text: "Opening line", start: 0),
            row("second", text: "A HIDDEN feature", start: 10),
            row("third", text: "Another hidden detail", start: 20),
        ]

        let matches = TranscriptBrowserNavigation.rows(
            rows,
            matching: " hidden "
        )

        #expect(matches.map(\.id) == ["second", "third"])
    }

    @Test func currentRowUsesHalfOpenTimelineRanges() {
        let rows = [
            row("first", text: "First", start: 0),
            row("second", text: "Second", start: 10),
        ]
        let index = TranscriptBrowserTimelineIndex(sortedRows: rows)

        #expect(index.currentRow(at: -1) == nil)
        #expect(index.currentRow(at: 0)?.id == "first")
        #expect(index.currentRow(at: 9)?.id == "first")
        #expect(index.currentRow(at: 10)?.id == "second")
        #expect(index.currentRow(at: 19)?.id == "second")
        #expect(index.currentRow(at: 20) == nil)
    }

    @Test func currentRowFallsBackToEarlierOverlappingRow() {
        let rows = [
            row("long", text: "Long transcript", start: 0, duration: 100),
            row("short", text: "Short transcript", start: 10, duration: 5),
        ]
        let index = TranscriptBrowserTimelineIndex(sortedRows: rows)

        #expect(index.currentRow(at: 14)?.id == "short")
        #expect(index.currentRow(at: 15)?.id == "long")
        #expect(index.currentRow(at: 99)?.id == "long")
        #expect(index.currentRow(at: 100) == nil)
    }

    @Test func mapsClipRelativeWordTimingsOntoTheTimeline() {
        let words = [
            WordTiming(text: " Hello ", startFrame: 0, endFrame: 6),
            WordTiming(text: "   ", startFrame: 6, endFrame: 8),
            WordTiming(text: "world", startFrame: 8, endFrame: 8),
            WordTiming(text: "world", startFrame: 8, endFrame: 14),
        ].compactMap { $0.shifted(by: 30) }

        #expect(words == [
            WordTiming(text: "Hello", startFrame: 30, endFrame: 36),
            WordTiming(text: "world", startFrame: 38, endFrame: 44),
        ])
    }

    @Test func captionFallbackExposesWordTimings() throws {
        var cue = Fixtures.clip(
            id: "cue",
            mediaRef: "text",
            mediaType: .text,
            start: 10,
            duration: 20
        )
        cue.textContent = "Hello there"
        cue.captionGroupId = "imported-vtt"
        cue.wordTimings = [
            WordTiming(text: "Hello", startFrame: 0, endFrame: 8),
            WordTiming(text: "there", startFrame: 8, endFrame: 20),
        ]
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [cue])])

        let fallback = try #require(TranscriptBrowserNavigation.captionFallbacks(in: timeline).first)
        #expect(fallback.rows[0].words == [
            WordTiming(text: "Hello", startFrame: 10, endFrame: 18),
            WordTiming(text: "there", startFrame: 18, endFrame: 30),
        ])
    }

    @Test func missingWordTimingsSelectTheWholeCue() {
        let words = TranscriptBrowserNavigation.words(from: [
            row("cue", text: "One two three", start: 0, duration: 30),
        ])
        #expect(words.map(\.text) == ["One two three"])
        #expect(
            TranscriptBrowserNavigation.timelineRange(
                from: words, startIndex: 0, endIndex: 0
            ) == TimelineRangeSelection(startFrame: 0, endFrame: 30)
        )
    }

    @Test func wordSelectionMapsToATimelineRange() {
        let words = TranscriptBrowserNavigation.words(from: [
            EditorViewModel.TimelineTranscriptRow(
                id: "line",
                clipId: "source",
                text: "One two three",
                startFrame: 0,
                endFrame: 30,
                words: [
                    WordTiming(text: "One", startFrame: 0, endFrame: 8),
                    WordTiming(text: "two", startFrame: 8, endFrame: 16),
                    WordTiming(text: "three", startFrame: 16, endFrame: 30),
                ]
            )
        ])

        #expect(
            TranscriptBrowserNavigation.timelineRange(
                from: words, startIndex: 1, endIndex: 1
            ) == TimelineRangeSelection(startFrame: 8, endFrame: 16)
        )
        #expect(
            TranscriptBrowserNavigation.timelineRange(
                from: words, startIndex: 0, endIndex: 1
            ) == TimelineRangeSelection(startFrame: 0, endFrame: 16)
        )
    }

    @Test func wordSelectionSpansAcrossCueRows() {
        let words = TranscriptBrowserNavigation.words(from: [
            EditorViewModel.TimelineTranscriptRow(
                id: "first",
                clipId: "source",
                text: "Hello there",
                startFrame: 0,
                endFrame: 16,
                words: [
                    WordTiming(text: "Hello", startFrame: 0, endFrame: 8),
                    WordTiming(text: "there", startFrame: 8, endFrame: 16),
                ]
            ),
            EditorViewModel.TimelineTranscriptRow(
                id: "second",
                clipId: "source",
                text: "How are you",
                startFrame: 30,
                endFrame: 50,
                words: [
                    WordTiming(text: "How", startFrame: 30, endFrame: 36),
                    WordTiming(text: "are", startFrame: 36, endFrame: 42),
                    WordTiming(text: "you", startFrame: 42, endFrame: 50),
                ]
            ),
        ])

        #expect(
            TranscriptBrowserNavigation.timelineRange(
                from: words, startIndex: 1, endIndex: 4
            ) == TimelineRangeSelection(startFrame: 8, endFrame: 50)
        )
    }

    @Test func wordHitTestingPrefersTheRectContainingThePoint() {
        let frames: [Int: CGRect] = [
            0: CGRect(x: 0, y: 0, width: 40, height: 12),
            1: CGRect(x: 40, y: 0, width: 40, height: 12),
            2: CGRect(x: 0, y: 16, width: 80, height: 12),
        ]

        #expect(TranscriptBrowserNavigation.wordIndex(at: CGPoint(x: 45, y: 4), frames: frames) == 1)
        #expect(TranscriptBrowserNavigation.wordIndex(at: CGPoint(x: 10, y: 20), frames: frames) == 2)
        #expect(TranscriptBrowserNavigation.wordIndex(at: CGPoint(x: 90, y: 4), frames: frames) == 1)
    }
}
