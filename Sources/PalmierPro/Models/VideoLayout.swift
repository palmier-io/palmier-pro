import Foundation

struct LayoutRect: Equatable, Sendable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

struct LayoutSlot: Equatable, Sendable {
    let id: String
    let rect: LayoutRect
    var z: Int = 0
}

enum LayoutFit: String, Sendable {
    case fill
    case fit
}

enum VideoLayout: String, CaseIterable, Sendable {
    case full
    case sideBySide = "side_by_side"
    case topBottom = "top_bottom"
    case pipBottomRight = "pip_bottom_right"
    case pipBottomLeft = "pip_bottom_left"
    case pipTopRight = "pip_top_right"
    case pipTopLeft = "pip_top_left"
    case grid2x2 = "grid_2x2"
    case grid3x3 = "grid_3x3"
    case grid4x4 = "grid_4x4"
    case mainSidebar = "main_sidebar"
    case threeUp = "three_up"

    var displayName: String {
        switch self {
        case .full: L10n.key("Full Frame")
        case .sideBySide: L10n.key("Side by Side")
        case .topBottom: L10n.key("Top / Bottom")
        case .pipBottomRight: L10n.key("PiP Bottom Right")
        case .pipBottomLeft: L10n.key("PiP Bottom Left")
        case .pipTopRight: L10n.key("PiP Top Right")
        case .pipTopLeft: L10n.key("PiP Top Left")
        case .grid2x2: L10n.key("Grid 2×2")
        case .grid3x3: L10n.key("Grid 3×3")
        case .grid4x4: L10n.key("Grid 4×4")
        case .mainSidebar: L10n.key("Main + Sidebar")
        case .threeUp: L10n.key("Three-Up")
        }
    }

    private static let pipInset = 0.28
    private static let pipMargin = 0.035

    var slots: [LayoutSlot] {
        switch self {
        case .full:
            return [LayoutSlot(id: "main", rect: LayoutRect(x: 0, y: 0, w: 1, h: 1))]

        case .sideBySide:
            return [
                LayoutSlot(id: "left",  rect: LayoutRect(x: 0,   y: 0, w: 0.5, h: 1)),
                LayoutSlot(id: "right", rect: LayoutRect(x: 0.5, y: 0, w: 0.5, h: 1)),
            ]

        case .topBottom:
            return [
                LayoutSlot(id: "top",    rect: LayoutRect(x: 0, y: 0,   w: 1, h: 0.5)),
                LayoutSlot(id: "bottom", rect: LayoutRect(x: 0, y: 0.5, w: 1, h: 0.5)),
            ]

        case .pipBottomRight: return Self.pip(insetX: 1 - Self.pipMargin - Self.pipInset, insetY: 1 - Self.pipMargin - Self.pipInset)
        case .pipBottomLeft:  return Self.pip(insetX: Self.pipMargin,                     insetY: 1 - Self.pipMargin - Self.pipInset)
        case .pipTopRight:    return Self.pip(insetX: 1 - Self.pipMargin - Self.pipInset, insetY: Self.pipMargin)
        case .pipTopLeft:     return Self.pip(insetX: Self.pipMargin,                     insetY: Self.pipMargin)

        case .grid2x2: return Self.grid(rows: 2, columns: 2)
        case .grid3x3: return Self.grid(rows: 3, columns: 3)
        case .grid4x4: return Self.grid(rows: 4, columns: 4)

        case .mainSidebar:
            return [
                LayoutSlot(id: "main",    rect: LayoutRect(x: 0,   y: 0, w: 0.7, h: 1)),
                LayoutSlot(id: "sidebar", rect: LayoutRect(x: 0.7, y: 0, w: 0.3, h: 1)),
            ]

        case .threeUp:
            let third = 1.0 / 3.0
            return [
                LayoutSlot(id: "left",   rect: LayoutRect(x: 0,         y: 0, w: third, h: 1)),
                LayoutSlot(id: "center", rect: LayoutRect(x: third,     y: 0, w: third, h: 1)),
                LayoutSlot(id: "right",  rect: LayoutRect(x: third * 2, y: 0, w: third, h: 1)),
            ]
        }
    }

    private static func grid(rows: Int, columns: Int) -> [LayoutSlot] {
        let width = 1.0 / Double(columns), height = 1.0 / Double(rows)
        return (0..<rows).flatMap { row in
            (0..<columns).map { column in
                LayoutSlot(
                    id: "r\(row + 1)c\(column + 1)",
                    rect: LayoutRect(x: Double(column) * width, y: Double(row) * height, w: width, h: height)
                )
            }
        }
    }

    private static func pip(insetX: Double, insetY: Double) -> [LayoutSlot] {
        [
            LayoutSlot(id: "main",  rect: LayoutRect(x: 0, y: 0, w: 1, h: 1), z: 0),
            LayoutSlot(id: "inset", rect: LayoutRect(x: insetX, y: insetY, w: pipInset, h: pipInset), z: 1),
        ]
    }
}
