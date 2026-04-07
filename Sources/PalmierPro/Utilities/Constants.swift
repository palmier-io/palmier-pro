import Foundation

enum Layout {
    // Media panel
    static let mediaPanelDefault: CGFloat = 220
    static let mediaPanelMin: CGFloat = 180
    static let mediaPanelMax: CGFloat = 400

    // Inspector
    static let inspectorDefault: CGFloat = 260
    static let inspectorMin: CGFloat = 200
    static let inspectorMax: CGFloat = 360

    // Toolbar
    static let toolbarHeight: CGFloat = 38

    // Timeline
    static let timelineMinHeight: CGFloat = 200
    static let trackHeight: CGFloat = 60
    static let rulerHeight: CGFloat = 24
    static let trackHeaderWidth: CGFloat = 100
    static let dropZoneHeight: CGFloat = 30
    static let insertThreshold: CGFloat = 10

    // Preview
    static let previewMinWidth: CGFloat = 300
}

enum Defaults {
    static let fps = 30
    static let canvasWidth = 1920
    static let canvasHeight = 1080
    static let pixelsPerFrame: Double = 4.0
}

enum Snap {
    static let thresholdPixels: Double = 8.0
    static let stickyMultiplier: Double = 2.5
    static let playheadMultiplier: Double = 1.5
}

enum TrackSize {
    static let minHeight: CGFloat = 32
    static let maxHeight: CGFloat = 200
    static let resizeHandleZone: CGFloat = 6
}

enum Zoom {
    static let min: Double = 0.5
    static let max: Double = 40.0
    static let scrollSensitivity: Double = 0.1
}

enum Trim {
    static let handleWidth: CGFloat = 4.0
    static let clipCornerRadius: CGFloat = 3.0
}
