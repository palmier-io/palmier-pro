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
    case mainSidebar = "main_sidebar"
    case threeUp = "three_up"

    var displayName: String {
        switch self {
        case .full: "Full Frame"
        case .sideBySide: "Side by Side"
        case .topBottom: "Top / Bottom"
        case .pipBottomRight: "PiP Bottom Right"
        case .pipBottomLeft: "PiP Bottom Left"
        case .pipTopRight: "PiP Top Right"
        case .pipTopLeft: "PiP Top Left"
        case .grid2x2: "Grid 2×2"
        case .mainSidebar: "Main + Sidebar"
        case .threeUp: "Three-Up"
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

        case .grid2x2:
            return [
                LayoutSlot(id: "top_left",     rect: LayoutRect(x: 0,   y: 0,   w: 0.5, h: 0.5)),
                LayoutSlot(id: "top_right",    rect: LayoutRect(x: 0.5, y: 0,   w: 0.5, h: 0.5)),
                LayoutSlot(id: "bottom_left",  rect: LayoutRect(x: 0,   y: 0.5, w: 0.5, h: 0.5)),
                LayoutSlot(id: "bottom_right", rect: LayoutRect(x: 0.5, y: 0.5, w: 0.5, h: 0.5)),
            ]

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

    private static func pip(insetX: Double, insetY: Double) -> [LayoutSlot] {
        [
            LayoutSlot(id: "main",  rect: LayoutRect(x: 0, y: 0, w: 1, h: 1), z: 0),
            LayoutSlot(id: "inset", rect: LayoutRect(x: insetX, y: insetY, w: pipInset, h: pipInset), z: 1),
        ]
    }
}
