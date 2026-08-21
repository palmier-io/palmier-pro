import SwiftUI

struct TranscriptBrowserTokenID: Hashable, Sendable {
    let rowId: String
    let wordIndex: Int
}

struct TranscriptBrowserToken: Equatable, Sendable {
    let id: TranscriptBrowserTokenID
    let clipId: String
    let text: String
    let startFrame: Int
    let endFrame: Int
}

enum TranscriptBrowserSelectionAnchor: Equatable, Sendable {
    case token(TranscriptBrowserTokenID)
    case row(String)
}

enum TranscriptTokenFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension TranscriptBrowserNavigation {
    static func tokens(
        from rows: [EditorViewModel.TimelineTranscriptRow]
    ) -> [TranscriptBrowserToken] {
        rows.flatMap { row -> [TranscriptBrowserToken] in
            if row.words.isEmpty {
                return [
                    TranscriptBrowserToken(
                        id: TranscriptBrowserTokenID(rowId: row.id, wordIndex: 0),
                        clipId: row.clipId,
                        text: row.text,
                        startFrame: row.startFrame,
                        endFrame: row.endFrame
                    )
                ]
            }
            return row.words.enumerated().map { index, word in
                TranscriptBrowserToken(
                    id: TranscriptBrowserTokenID(rowId: row.id, wordIndex: index),
                    clipId: row.clipId,
                    text: word.text,
                    startFrame: word.startFrame,
                    endFrame: word.endFrame
                )
            }
        }
    }

    static func tokenIndices(
        inRow rowId: String,
        tokens: [TranscriptBrowserToken]
    ) -> Range<Int>? {
        guard let first = tokens.firstIndex(where: { $0.id.rowId == rowId }) else { return nil }
        var last = first
        while last + 1 < tokens.count, tokens[last + 1].id.rowId == rowId {
            last += 1
        }
        return first..<(last + 1)
    }

    static func index(
        of id: TranscriptBrowserTokenID,
        in tokens: [TranscriptBrowserToken]
    ) -> Int? {
        tokens.firstIndex { $0.id == id }
    }

    static func timelineRange(
        from tokens: [TranscriptBrowserToken],
        startIndex: Int,
        endIndex: Int
    ) -> TimelineRangeSelection? {
        guard tokens.indices.contains(startIndex), tokens.indices.contains(endIndex) else {
            return nil
        }
        let lower = min(startIndex, endIndex)
        let upper = max(startIndex, endIndex)
        let start = tokens[lower...upper].map(\.startFrame).min() ?? tokens[lower].startFrame
        let end = tokens[lower...upper].map(\.endFrame).max() ?? tokens[upper].endFrame
        let range = TimelineRangeSelection(startFrame: start, endFrame: max(start + 1, end))
        return range.isValid ? range : nil
    }

    static func selectedText(
        from tokens: [TranscriptBrowserToken],
        startIndex: Int,
        endIndex: Int
    ) -> String {
        guard tokens.indices.contains(startIndex), tokens.indices.contains(endIndex) else {
            return ""
        }
        let lower = min(startIndex, endIndex)
        let upper = max(startIndex, endIndex)
        var lines: [String] = []
        var currentRow: String?
        var words: [String] = []
        for token in tokens[lower...upper] {
            if currentRow != token.id.rowId {
                if !words.isEmpty { lines.append(words.joined(separator: " ")) }
                words = [token.text]
                currentRow = token.id.rowId
            } else {
                words.append(token.text)
            }
        }
        if !words.isEmpty { lines.append(words.joined(separator: " ")) }
        return lines.joined(separator: "\n")
    }

    static func intersectingIndices(
        tokens: [TranscriptBrowserToken],
        range: TimelineRangeSelection?
    ) -> [Int] {
        guard let range = range?.normalized, range.isValid else { return [] }
        return tokens.indices.filter { index in
            let token = tokens[index]
            return token.startFrame < range.endFrame && token.endFrame > range.startFrame
        }
    }

    static func tokenIndex(at point: CGPoint, frames: [Int: CGRect]) -> Int? {
        if let exact = frames.first(where: { $0.value.contains(point) }) {
            return exact.key
        }
        let rowHits = frames.filter { $0.value.minY <= point.y && point.y < $0.value.maxY }
        let candidates = rowHits.isEmpty ? frames : rowHits
        return candidates.min { lhs, rhs in
            distance(point, lhs.value) < distance(point, rhs.value)
        }?.key
    }

    static func span(
        fromAnchor anchor: TranscriptBrowserSelectionAnchor,
        toTokenIndex: Int? = nil,
        toRowId: String? = nil,
        tokens: [TranscriptBrowserToken]
    ) -> (start: Int, end: Int)? {
        guard let origin = originSpan(anchor: anchor, tokens: tokens) else { return nil }
        let destination: Range<Int>
        if let toRowId, let row = tokenIndices(inRow: toRowId, tokens: tokens) {
            destination = row
        } else if let toTokenIndex, tokens.indices.contains(toTokenIndex) {
            destination = toTokenIndex..<(toTokenIndex + 1)
        } else {
            return (origin.lowerBound, origin.upperBound - 1)
        }
        let start = min(origin.lowerBound, destination.lowerBound)
        let end = max(origin.upperBound, destination.upperBound) - 1
        return (start, end)
    }

    private static func originSpan(
        anchor: TranscriptBrowserSelectionAnchor,
        tokens: [TranscriptBrowserToken]
    ) -> Range<Int>? {
        switch anchor {
        case .token(let id):
            guard let index = index(of: id, in: tokens) else { return nil }
            return index..<(index + 1)
        case .row(let rowId):
            return tokenIndices(inRow: rowId, tokens: tokens)
        }
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
