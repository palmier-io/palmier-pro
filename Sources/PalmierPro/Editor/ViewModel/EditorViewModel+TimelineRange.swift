extension EditorViewModel {
    var validSelectedTimelineRange: TimelineRangeSelection? {
        guard let range = selectedTimelineRange?.normalized, range.isValid else { return nil }
        return range
    }

    func markTimelineRangeStart(atFrame frame: Int? = nil) {
        let start = max(0, frame ?? activeFrame)
        selectedTimelineRange = TimelineRangeSelection(
            startFrame: start,
            endFrame: selectedTimelineRange?.endFrame ?? start
        )
    }

    func markTimelineRangeEnd(atFrame frame: Int? = nil) {
        let end = max(0, frame ?? activeFrame)
        selectedTimelineRange = TimelineRangeSelection(
            startFrame: selectedTimelineRange?.startFrame ?? end,
            endFrame: end
        )
    }

    func setTimelineRange(startFrame: Int, endFrame: Int) {
        selectedTimelineRange = TimelineRangeSelection(
            startFrame: max(0, startFrame),
            endFrame: max(0, endFrame)
        )
    }

    func keepValidTimelineRangeOrClear() {
        guard let range = validSelectedTimelineRange else {
            selectedTimelineRange = nil
            return
        }
        selectedTimelineRange = range
    }

    func clearTimelineRange() {
        selectedTimelineRange = nil
    }
}
