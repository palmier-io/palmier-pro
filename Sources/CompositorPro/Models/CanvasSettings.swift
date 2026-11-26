import CoreGraphics
import Foundation

/// Arbitrary canvas size plus optional background for the preview/render. Presets remain valid;
/// out-of-range sizes clamp instead of failing.
struct CanvasSettings: Codable, Sendable, Equatable {
    static let minimumWidth = 160
    static let minimumHeight = 90
    static let maximumWidth = 7_680
    static let maximumHeight = 4_320

    var width: Int
    var height: Int
    var background: CanvasBackground

    init(width: Int, height: Int, background: CanvasBackground = .none) {
        self.width = Self.clampWidth(width)
        self.height = Self.clampHeight(height)
        self.background = background
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            width: try values.decode(Int.self, forKey: .width),
            height: try values.decode(Int.self, forKey: .height),
            background: try values.decodeIfPresent(CanvasBackground.self, forKey: .background) ?? .none
        )
    }

    static func clampWidth(_ value: Int) -> Int { min(maximumWidth, max(minimumWidth, value)) }
    static func clampHeight(_ value: Int) -> Int { min(maximumHeight, max(minimumHeight, value)) }
}

enum CanvasBackground: Codable, Sendable, Equatable {
    case none
    case solid(TextStyle.RGBA)
    case gradient(start: TextStyle.RGBA, end: TextStyle.RGBA)
    case blur(radius: Double)

    var kind: String {
        switch self {
        case .none: "none"
        case .solid: "solid"
        case .gradient: "gradient"
        case .blur: "blur"
        }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .kind) {
        case "solid":
            self = .solid(try values.decode(TextStyle.RGBA.self, forKey: .color))
        case "gradient":
            self = .gradient(
                start: try values.decode(TextStyle.RGBA.self, forKey: .start),
                end: try values.decode(TextStyle.RGBA.self, forKey: .end)
            )
        case "blur":
            let radius = try values.decode(Double.self, forKey: .radius)
            self = .blur(radius: radius.isFinite ? min(100, max(0, radius)) : 0)
        default:
            self = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        switch self {
        case .none, .blur:
            if case .blur(let radius) = self {
                try values.encode(min(100, max(0, radius)), forKey: .radius)
            }
        case .solid(let color):
            try values.encode(color, forKey: .color)
        case .gradient(let start, let end):
            try values.encode(start, forKey: .start)
            try values.encode(end, forKey: .end)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, color, start, end, radius
    }
}

/// Preview zoom and pan with clamping so the canvas can never be panned fully out of view.
struct PreviewZoom: Sendable, Equatable {
    static let minimumScale = 0.25
    static let maximumScale = 4.0

    var scale: Double = 1
    var panX: Double = 0
    var panY: Double = 0

    mutating func setScale(_ value: Double) {
        scale = value.isFinite ? min(Self.maximumScale, max(Self.minimumScale, value)) : 1
        clampPan()
    }

    mutating func setPan(x: Double, y: Double, viewport: CGSize) {
        panX = x.isFinite ? x : 0
        panY = y.isFinite ? y : 0
        clampPan(viewport: viewport)
    }

    /// Pan is limited to half the scaled overflow, so some content always remains visible.
    mutating func clampPan(viewport: CGSize = CGSize(width: 1_000, height: 1_000)) {
        let limitX = max(0, (Double(viewport.width) * scale - Double(viewport.width)) / 2)
        let limitY = max(0, (Double(viewport.height) * scale - Double(viewport.height)) / 2)
        panX = min(limitX, max(-limitX, panX))
        panY = min(limitY, max(-limitY, panY))
    }
}
