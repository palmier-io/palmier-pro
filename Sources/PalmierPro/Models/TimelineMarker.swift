import Foundation

struct TimelineMarker: Codable, Sendable, Equatable, Hashable, Identifiable {
    enum Status: String, Codable, Sendable, CaseIterable {
        case open
        case review
        case resolved
    }

    static let maximumNameLength = 120
    static let maximumCommentLength = 4_000
    static let defaultColor = TextStyle.RGBA(r: 0, g: 0.478, b: 1, a: 1)

    var id: String = UUID().uuidString
    var name: String
    var startFrame: Int
    var durationFrames: Int = 0
    var color: TextStyle.RGBA = defaultColor
    var comment: String = ""
    var status: Status = .open

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

extension TimelineMarker {
    private enum CodingKeys: String, CodingKey {
        case id, name, startFrame, durationFrames, color, comment, status
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            name: try values.decode(String.self, forKey: .name),
            startFrame: try values.decode(Int.self, forKey: .startFrame),
            durationFrames: try values.decode(Int.self, forKey: .durationFrames),
            color: try values.decode(TextStyle.RGBA.self, forKey: .color),
            comment: try values.decode(String.self, forKey: .comment),
            status: try values.decodeIfPresent(Status.self, forKey: .status) ?? .open
        )
    }
}

enum TimelineMarkerValidationError: Error, Equatable {
    case invalidName
    case invalidComment
    case invalidRange
}
