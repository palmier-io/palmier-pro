struct SilenceRemovalSettings: Equatable, Sendable {
    static let minimumPauseRange = 0.25...3.0
    static let speechPaddingRange = 0.0...0.5

    static let `default` = SilenceRemovalSettings(
        uncheckedMinimumPauseSeconds: 0.5,
        uncheckedSpeechPaddingSeconds: 0.15
    )

    let minimumPauseSeconds: Double
    let speechPaddingSeconds: Double

    init?(minimumPauseSeconds: Double, speechPaddingSeconds: Double) {
        guard minimumPauseSeconds.isFinite,
              speechPaddingSeconds.isFinite,
              Self.minimumPauseRange.contains(minimumPauseSeconds),
              Self.speechPaddingRange.contains(speechPaddingSeconds) else { return nil }
        self.init(
            uncheckedMinimumPauseSeconds: minimumPauseSeconds,
            uncheckedSpeechPaddingSeconds: speechPaddingSeconds
        )
    }

    private init(uncheckedMinimumPauseSeconds: Double, uncheckedSpeechPaddingSeconds: Double) {
        self.minimumPauseSeconds = uncheckedMinimumPauseSeconds
        self.speechPaddingSeconds = uncheckedSpeechPaddingSeconds
    }
}

enum SilenceRemovalPlanner {
    static func removableMask(
        from quietNonSpeechMask: [Bool],
        settings: SilenceRemovalSettings,
        cellDuration: Double = VoiceActivity.chunkDuration
    ) -> [Bool] {
        guard !quietNonSpeechMask.isEmpty, cellDuration.isFinite, cellDuration > 0 else { return [] }
        let minimumCells = cellCount(
            for: settings.minimumPauseSeconds,
            cellDuration: cellDuration,
            maximum: quietNonSpeechMask.count + 1
        )
        let paddingCells = cellCount(
            for: settings.speechPaddingSeconds,
            cellDuration: cellDuration,
            maximum: quietNonSpeechMask.count
        )
        var removable = [Bool](repeating: false, count: quietNonSpeechMask.count)
        var i = 0

        while i < quietNonSpeechMask.count {
            guard quietNonSpeechMask[i] else {
                i += 1
                continue
            }
            var j = i + 1
            while j < quietNonSpeechMask.count, quietNonSpeechMask[j] { j += 1 }
            if j - i >= minimumCells {
                let start = i + (i > 0 ? paddingCells : 0)
                let end = j - (j < quietNonSpeechMask.count ? paddingCells : 0)
                if start < end {
                    for cell in start..<end { removable[cell] = true }
                }
            }
            i = j
        }
        return removable
    }

    /// Clip-visible removable ranges in source-frame coordinates. These are the source of truth
    /// for both timeline shading and removal, including unpadded exposed clip edges.
    static func visibleRemovableRanges(
        from removableMask: [Bool],
        visibleSourceRange: Range<Double>,
        framesPerSecond: Int,
        settings: SilenceRemovalSettings,
        cellDuration: Double = VoiceActivity.chunkDuration
    ) -> [Range<Double>] {
        let cellFrames = cellDuration * Double(max(1, framesPerSecond))
        guard cellFrames.isFinite, cellFrames > 0,
              visibleSourceRange.lowerBound.isFinite,
              visibleSourceRange.upperBound.isFinite else { return [] }
        let visibleCells = (visibleSourceRange.lowerBound / cellFrames)..<(visibleSourceRange.upperBound / cellFrames)
        return visibleRemovableCellRanges(
            from: removableMask,
            visibleRange: visibleCells,
            settings: settings,
            cellDuration: cellDuration
        ).map { ($0.lowerBound * cellFrames)..<($0.upperBound * cellFrames) }
    }

    private static func visibleRemovableCellRanges(
        from removableMask: [Bool],
        visibleRange: Range<Double>,
        settings: SilenceRemovalSettings,
        cellDuration: Double
    ) -> [Range<Double>] {
        guard !removableMask.isEmpty, !visibleRange.isEmpty,
              visibleRange.lowerBound.isFinite, visibleRange.upperBound.isFinite,
              cellDuration.isFinite, cellDuration > 0 else { return [] }
        let edgePadding = Double(cellCount(
            for: settings.speechPaddingSeconds,
            cellDuration: cellDuration,
            maximum: removableMask.count
        ))
        let scanStart = Int(max(
            0,
            min(Double(removableMask.count), (visibleRange.lowerBound - edgePadding).rounded(.down))
        ))
        let scanEnd = Int(max(
            Double(scanStart),
            min(Double(removableMask.count), (visibleRange.upperBound + edgePadding).rounded(.up))
        ))
        var ranges: [Range<Double>] = []
        var i = scanStart
        while i < scanEnd {
            guard removableMask[i] else { i += 1; continue }
            var j = i + 1
            while j < scanEnd, removableMask[j] { j += 1 }
            let sourceRange = Double(i)..<Double(j)
            let expanded = expandingToVisibleEdges(
                sourceRange,
                within: visibleRange,
                edgePadding: edgePadding
            )
            if expanded.overlaps(visibleRange) {
                let start = max(expanded.lowerBound, visibleRange.lowerBound)
                let end = min(expanded.upperBound, visibleRange.upperBound)
                if start < end { ranges.append(start..<end) }
            }
            i = j
        }
        return ranges
    }

    private static func expandingToVisibleEdges(
        _ removableRange: Range<Double>,
        within visibleRange: Range<Double>,
        edgePadding: Double
    ) -> Range<Double> {
        guard edgePadding >= 0 else { return removableRange }
        let start = removableRange.upperBound > visibleRange.lowerBound
            && removableRange.lowerBound <= visibleRange.lowerBound + edgePadding
            ? visibleRange.lowerBound
            : removableRange.lowerBound
        let end = removableRange.lowerBound < visibleRange.upperBound
            && removableRange.upperBound >= visibleRange.upperBound - edgePadding
            ? visibleRange.upperBound
            : removableRange.upperBound
        return start..<end
    }

    private static func cellCount(for seconds: Double, cellDuration: Double, maximum: Int) -> Int {
        let count = (seconds / cellDuration).rounded(.up)
        guard count.isFinite, count < Double(maximum) else { return maximum }
        return max(0, Int(count))
    }
}
