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
    /// Optional semantic label; `color` keeps rendering-compatible values for older files.
    var colorLabel: MarkerColorLabel?
    var comment: String = ""
    var status: Status = .open

    var endFrame: Int { startFrame + durationFrames }
    var isRange: Bool { durationFrames > 0 }

    /// Applies the label's palette color when one is set.
    mutating func adoptColorLabel() {
        guard let colorLabel else { return }
        color = colorLabel.color
    }

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

enum MarkerColorLabel: String, Codable, Sendable, CaseIterable {
    case blue, green, yellow, orange, red, purple, gray, teal

    var color: TextStyle.RGBA {
        switch self {
        case .blue: .init(r: 0, g: 0.478, b: 1, a: 1)
        case .green: .init(r: 0.2, g: 0.78, b: 0.35, a: 1)
        case .yellow: .init(r: 0.95, g: 0.78, b: 0.2, a: 1)
        case .orange: .init(r: 0.98, g: 0.55, b: 0.16, a: 1)
        case .red: .init(r: 0.92, g: 0.26, b: 0.26, a: 1)
        case .purple: .init(r: 0.62, g: 0.4, b: 0.95, a: 1)
        case .gray: .init(r: 0.55, g: 0.58, b: 0.62, a: 1)
        case .teal: .init(r: 0.15, g: 0.72, b: 0.72, a: 1)
        }
    }
}

extension TimelineMarker {
    private enum CodingKeys: String, CodingKey {
        case id, name, startFrame, durationFrames, color, colorLabel, comment, status
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            name: try values.decode(String.self, forKey: .name),
            startFrame: try values.decode(Int.self, forKey: .startFrame),
            durationFrames: try values.decode(Int.self, forKey: .durationFrames),
            color: try values.decode(TextStyle.RGBA.self, forKey: .color),
            colorLabel: try values.decodeIfPresent(MarkerColorLabel.self, forKey: .colorLabel),
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
