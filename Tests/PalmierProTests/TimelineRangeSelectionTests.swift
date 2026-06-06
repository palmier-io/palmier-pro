import Testing
@testable import PalmierPro

@Suite("Timeline range selection")
struct TimelineRangeSelectionTests {

    @Test func normalizesReversedRanges() {
        let range = TimelineRangeSelection(startFrame: 90, endFrame: 30).normalized

        #expect(range.startFrame == 30)
        #expect(range.endFrame == 90)
        #expect(range.isValid)
    }

    @Test func containsUsesHalfOpenBounds() {
        let range = TimelineRangeSelection(startFrame: 30, endFrame: 90)

        #expect(range.contains(frame: 30))
        #expect(range.contains(frame: 89))
        #expect(!range.contains(frame: 90))
    }
}

@Suite("EditorViewModel - timeline range")
@MainActor
struct EditorTimelineRangeTests {

    @Test func markStartAndEndUsePlayhead() {
        let editor = EditorViewModel()
        editor.currentFrame = 30
        editor.markTimelineRangeStart()
        editor.currentFrame = 90
        editor.markTimelineRangeEnd()

        #expect(editor.selectedTimelineRange == TimelineRangeSelection(startFrame: 30, endFrame: 90))
    }

    @Test func invalidRangeClearsOnCommit() {
        let editor = EditorViewModel()
        editor.setTimelineRange(startFrame: 30, endFrame: 30)

        editor.keepValidTimelineRangeOrClear()

        #expect(editor.selectedTimelineRange == nil)
    }

    @Test func validSelectedTimelineRangeNormalizesAndRejectsInvalidRanges() {
        let editor = EditorViewModel()

        editor.setTimelineRange(startFrame: 90, endFrame: 30)
        #expect(editor.validSelectedTimelineRange == TimelineRangeSelection(startFrame: 30, endFrame: 90))

        editor.setTimelineRange(startFrame: 30, endFrame: 30)
        #expect(editor.validSelectedTimelineRange == nil)
    }
}
