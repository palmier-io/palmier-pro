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
}
