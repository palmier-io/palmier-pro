import Foundation

enum LayoutPreset: String, CaseIterable {
    case `default`
    case media
    case vertical

    var label: String {
        switch self {
        case .default: "Default"
        case .media: "Media"
        case .vertical: "Vertical"
        }
    }

    var icon: String {
        switch self {
        case .default: "rectangle.split.3x1"
        case .media: "sidebar.left"
        case .vertical: "sidebar.right"
        }
    }
}

enum Layout {
    // Media panel
    static let mediaPanelDefault: CGFloat = 220
    static let mediaPanelMin: CGFloat = 240
    static let mediaPanelMax: CGFloat = 900

    // Inspector
    static let inspectorDefault: CGFloat = 260
    static let inspectorMin: CGFloat = 150
    static let inspectorMax: CGFloat = 600

    // Agent panel
    static let agentPanelDefault: CGFloat = 240
    static let agentPanelMin: CGFloat = 240
    static let agentPanelMax: CGFloat = 600

    // Headers & toolbars
    static let panelHeaderHeight: CGFloat = 28
    static let toolbarHeight: CGFloat = 38

    // Timeline
    static let timelineMinHeight: CGFloat = 100
    static let timelineMaxHeight: CGFloat = 700
    static let trackHeight: CGFloat = 50
    static let rulerHeight: CGFloat = 24
    static let trackHeaderWidth: CGFloat = 100
    static let dropZoneHeight: CGFloat = 60
    static let insertThreshold: CGFloat = 10

    // Preview
    static let previewMinWidth: CGFloat = 200
    static let previewMaxWidth: CGFloat = 1200
}

enum Defaults {
    static let pixelsPerFrame: Double = 4.0
    static let imageDurationSeconds: Double = 5.0
    static let audioTTSDurationSeconds: Double = 10.0
    static let audioMusicDurationSeconds: Double = 60.0
    static let textDurationSeconds: Double = 3.0
    static let aspectTolerance: Double = 0.02
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
    static let min: Double = 0.05
    static let max: Double = 40.0
    static let scrollSensitivity: Double = 0.1
    static let fitAllBuffer: Double = 3.0
}

enum Trim {
    static let handleWidth: CGFloat = 4.0
    static let clipCornerRadius: CGFloat = 3.0
}

enum Project {
    static let fileExtension = "palmier"
    static let registryFilename = "project-registry.json"
    static let typeIdentifier = "io.palmier.project"
    static let defaultProjectName = "Untitled Project"
    static let timelineFilename = "project.json"
    static let manifestFilename = "media.json"
    static let thumbnailFilename = "thumbnail.jpg"
    static let mediaDirectoryName = "media"

    static let storageDirectory: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Palmier Pro", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

func gcd(_ a: Int, _ b: Int) -> Int {
    b == 0 ? a : gcd(b, a % b)
}
