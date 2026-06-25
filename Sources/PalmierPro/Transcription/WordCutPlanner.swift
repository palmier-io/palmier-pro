import Foundation

enum CutAggressiveness: String, Sendable, CaseIterable {
    case tight, balanced, loose
    var keptGapMs: Double { switch self { case .tight: 60; case .balanced: 150; case .loose: 320 } }
}

enum WordCutPlanner {
    struct Word: Equatable {
        let startFrame: Int, endFrame: Int, selected: Bool
    }

    static func cutRanges(words: [Word], clipStart: Int, clipEnd: Int, keepGapFrames: Int) -> [FrameRange] {
        let words = words.filter { $0.endFrame > $0.startFrame }
        guard clipEnd > clipStart, !words.isEmpty else { return [] }
        let half = max(0, keepGapFrames / 2)
        var ranges: [FrameRange] = []
        var k = 0
        while k < words.count {
            guard words[k].selected else { k += 1; continue }
            var l = k
            while l + 1 < words.count, words[l + 1].selected { l += 1 }
            let left = k > 0 ? words[k - 1].endFrame : clipStart
            let right = l + 1 < words.count ? words[l + 1].startFrame : clipEnd
            let runStart = words[k].startFrame, runEnd = words[l].endFrame
            let keepBefore = min(max(0, runStart - left), half)
            let keepAfter = min(max(0, right - runEnd), half)
            let start = max(clipStart, min(left + keepBefore, runStart))
            let end = min(clipEnd, max(runEnd, right - keepAfter))
            if end > start { ranges.append(FrameRange(start: start, end: end)) }
            k = l + 1
        }
        return mergeOverlapping(ranges)
    }

    private static func mergeOverlapping(_ ranges: [FrameRange]) -> [FrameRange] {
        let sorted = ranges.filter { $0.length > 0 }.sorted { $0.start < $1.start }
        guard var head = sorted.first else { return [] }
        var out: [FrameRange] = []
        for r in sorted.dropFirst() {
            if r.start <= head.end { head = FrameRange(start: head.start, end: max(head.end, r.end)) }
            else { out.append(head); head = r }
        }
        out.append(head)
        return out
    }
}
