import CoreGraphics
import Foundation

/// Per-clip mask shape with normalized geometry (0...1 in canvas space). Invalid values are
/// rejected at decode rather than silently clamped.
struct Mask: Codable, Sendable, Equatable {
    enum Shape: String, Codable, Sendable, CaseIterable {
        case rectangle, ellipse, split, star, heart, diamond, cinematicBars
    }

    static let maximumFeather = 0.5
    static let maximumStroke = 0.25

    var shape: Shape
    var centerX: Double
    var centerY: Double
    var width: Double
    var height: Double
    var rotationDegrees: Double
    var feather: Double
    var stroke: Double
    var invert: Bool

    init(shape: Shape = .rectangle, centerX: Double = 0.5, centerY: Double = 0.5,
         width: Double = 1, height: Double = 1, rotationDegrees: Double = 0,
         feather: Double = 0, stroke: Double = 0, invert: Bool = false) throws {
        self.shape = shape
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.rotationDegrees = rotationDegrees
        self.feather = feather
        self.stroke = stroke
        self.invert = invert
        try validate()
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.shape = try values.decode(Shape.self, forKey: .shape)
        self.centerX = try values.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.5
        self.centerY = try values.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.5
        self.width = try values.decodeIfPresent(Double.self, forKey: .width) ?? 1
        self.height = try values.decodeIfPresent(Double.self, forKey: .height) ?? 1
        self.rotationDegrees = try values.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0
        self.feather = try values.decodeIfPresent(Double.self, forKey: .feather) ?? 0
        self.stroke = try values.decodeIfPresent(Double.self, forKey: .stroke) ?? 0
        self.invert = try values.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        try validate()
    }

    func validate() throws {
        let numbers = [centerX, centerY, width, height, rotationDegrees, feather, stroke]
        guard numbers.allSatisfy({ $0.isFinite }) else { throw MaskValidationError.notFinite }
        guard centerX >= -1, centerX <= 2, centerY >= -1, centerY <= 2 else { throw MaskValidationError.outOfBounds }
        guard width > 0, width <= 4, height > 0, height <= 4 else { throw MaskValidationError.outOfBounds }
        guard feather >= 0, feather <= Self.maximumFeather else { throw MaskValidationError.invalidFeather }
        guard stroke >= 0, stroke <= Self.maximumStroke else { throw MaskValidationError.invalidStroke }
        guard abs(rotationDegrees) <= 3_600 else { throw MaskValidationError.outOfBounds }
    }
}

enum MaskValidationError: Error, Equatable {
    case notFinite
    case outOfBounds
    case invalidFeather
    case invalidStroke
}
