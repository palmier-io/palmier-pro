import Foundation

struct ShapeStyle: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case rect
        case oval
        case circle
        case arrow
        case line
    }

    var kind: Kind = .rect
    var stroke: Stroke = Stroke()
    var fill: Fill = Fill()
    /// rect only — normalized 0..0.5 of the shorter side
    var cornerRadius: Double = 0
    /// arrow only
    var arrowhead: Arrowhead = Arrowhead()
    /// arrow / line only — when set, transform is derived from these for hit-testing,
    /// but the path is drawn directly from the endpoints in canvas coords.
    var endpoints: Endpoints?

    struct Stroke: Codable, Sendable, Equatable {
        var enabled: Bool = true
        var color: TextStyle.RGBA = TextStyle.RGBA(r: 1, g: 0.231, b: 0.188, a: 1)
        /// Canvas points at the 1080p reference height; scaled at render time.
        var width: Double = 6
        /// Empty = solid. Values are pattern lengths (canvas points).
        var dash: [Double] = []
    }

    struct Fill: Codable, Sendable, Equatable {
        var enabled: Bool = false
        var color: TextStyle.RGBA = TextStyle.RGBA(r: 1, g: 0.231, b: 0.188, a: 0.25)
    }

    struct Arrowhead: Codable, Sendable, Equatable {
        enum Style: String, Codable, Sendable, CaseIterable {
            case triangle
            case open
            case none
        }
        var style: Style = .triangle
        /// Canvas points at the 1080p reference height.
        var size: Double = 24
    }

    /// Normalized 0..1 canvas coords. (0,0) top-left, (1,1) bottom-right.
    struct Endpoints: Codable, Sendable, Equatable {
        var fromX: Double
        var fromY: Double
        var toX: Double
        var toY: Double
        var controlX: Double?
        var controlY: Double?
    }

    private enum CodingKeys: String, CodingKey {
        case kind, stroke, fill, cornerRadius, arrowhead, endpoints
    }
}

extension ShapeStyle {
    /// Missing-key-tolerant decode — older projects without shape clips still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: (try? c.decode(Kind.self, forKey: .kind)) ?? .rect,
            stroke: (try? c.decode(Stroke.self, forKey: .stroke)) ?? Stroke(),
            fill: (try? c.decode(Fill.self, forKey: .fill)) ?? Fill(),
            cornerRadius: (try? c.decode(Double.self, forKey: .cornerRadius)) ?? 0,
            arrowhead: (try? c.decode(Arrowhead.self, forKey: .arrowhead)) ?? Arrowhead(),
            endpoints: try? c.decode(Endpoints.self, forKey: .endpoints)
        )
    }
}

extension ShapeStyle.Endpoints {
    /// Bounding box of the endpoints (and optional control point) in normalized canvas space.
    /// Returned with a small minimum size so degenerate horizontal/vertical arrows still have a box.
    var boundingBox: (centerX: Double, centerY: Double, width: Double, height: Double) {
        let minX = [fromX, toX, controlX ?? fromX].min() ?? 0
        let maxX = [fromX, toX, controlX ?? toX].max() ?? 1
        let minY = [fromY, toY, controlY ?? fromY].min() ?? 0
        let maxY = [fromY, toY, controlY ?? toY].max() ?? 1
        let w = max(0.001, maxX - minX)
        let h = max(0.001, maxY - minY)
        return (minX + w / 2, minY + h / 2, w, h)
    }
}
