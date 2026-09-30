struct TimelineRangeSelection: Equatable, Sendable {
    var startFrame: Int
    var endFrame: Int

    var normalized: Self {
        startFrame <= endFrame
            ? self
            : Self(startFrame: endFrame, endFrame: startFrame)
    }

    var isValid: Bool {
        let range = normalized
        return range.endFrame > range.startFrame
    }

    func contains(frame: Int) -> Bool {
        let range = normalized
        return frame >= range.startFrame && frame < range.endFrame
    }
}
