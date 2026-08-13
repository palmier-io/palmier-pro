import Foundation

struct TimelineMarker: Codable, Sendable, Equatable, Hashable, Identifiable {
    static let maximumNameLength = 120
    static let maximumCommentLength = 4_000
    static let defaultColor = TextStyle.RGBA(r: 0, g: 0.478, b: 1, a: 1)

    var id: String = UUID().uuidString
    var clipId: String?
    var name: String
    var startFrame: Int
    var durationFrames: Int = 0
    var color: TextStyle.RGBA = defaultColor
    var comment: String = ""

    var endFrame: Int { startFrame + durationFrames }
    var isRange: Bool { durationFrames > 0 }

    func intersects(_ range: Range<Int>) -> Bool {
        isRange
            ? startFrame < range.upperBound && endFrame > range.lowerBound
            : range.contains(startFrame)
    }

    mutating func rescaleFrames(by scale: Double) {
        let scaledEnd = Int((Double(endFrame) * scale).rounded())
        startFrame = max(0, Int((Double(startFrame) * scale).rounded()))
        durationFrames = isRange ? max(1, scaledEnd - startFrame) : 0
    }
}

enum TimelineMarkerValidationError: Error, Equatable {
    case invalidName
    case invalidComment
    case invalidRange
}

extension Timeline {
    mutating func copyMarkers(from sourceClipId: String, to clipId: String) {
        markers += markers.filter { $0.clipId == sourceClipId }.map {
            var copy = $0
            copy.id = UUID().uuidString
            copy.clipId = clipId
            return copy
        }
    }
}

extension Clip {
    func markerSourceFrame(at timelineFrame: Int) -> Int {
        trimStartFrame + Int((Double(timelineFrame - startFrame) * speed).rounded())
    }

    func markerTimelineFrame(at sourceFrame: Int) -> Int {
        startFrame + Int((Double(sourceFrame - trimStartFrame) / speed).rounded())
    }
}
