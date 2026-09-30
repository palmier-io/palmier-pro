import Foundation

enum Layout {
    // Media panel
    static let mediaPanelDefault: CGFloat = 500
    static let mediaPanelMin: CGFloat = 280 + AppTheme.GenerationPanel.minimumWidthAdjustment

    // Inspector
    static let inspectorDefault: CGFloat = AppTheme.EditorPanel.defaultWidth
    static let inspectorMin: CGFloat = AppTheme.EditorPanel.minimumWidth

    // Agent panel
    static let agentPanelMin: CGFloat = 240
    static let agentPanelMax: CGFloat = 640
    static let chatColumnMax: CGFloat = 640

    // Headers & toolbars
    static let panelHeaderHeight: CGFloat = AppTheme.IconSize.xl
    static let toolbarHeight: CGFloat = AppTheme.IconSize.mdLg + AppTheme.Spacing.sm * 2

    static let panelGap: CGFloat = 5

    // Timeline
    static let timelineMinHeight: CGFloat = 100
    static let timelineDefaultHeightFraction: CGFloat = 0.35
    static let trackHeight: CGFloat = TrackSize.defaultHeight
    static let rulerHeight: CGFloat = AppTheme.IconSize.lgXl
    static let trackHeaderDefaultWidth = AppTheme.ComponentSize.timelineTrackHeaderDefaultWidth
    static let trackHeaderMinimumWidth = AppTheme.ComponentSize.timelineTrackHeaderMinimumWidth
    static let trackHeaderMaximumWidth = AppTheme.ComponentSize.timelineTrackHeaderMaximumWidth
    static let trackHeaderResizeHitWidth = AppTheme.ComponentSize.timelineTrackHeaderResizeHitWidth
    static let dropZoneHeight: CGFloat = TrackSize.minHeight
    static let insertThreshold: CGFloat = 10
    static let dragThreshold: CGFloat = 3

    // Preview
    static let previewMinWidth: CGFloat = 400
    static let previewMinHeight: CGFloat = 320
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
    static let stickyMultiplier: Double = 1.5
    static let playheadMultiplier: Double = 1.5
}

enum TrackSize {
    static let defaultHeight: CGFloat = 44
    static let minHeight: CGFloat = 32
    static let maxHeight: CGFloat = 200
    static let resizeHandleZone: CGFloat = 6
}

enum Zoom {
    static let min: Double = 0.05
    static let floor: Double = 0.0001
    static let max: Double = 40.0
    static let toolbarStepFactor: Double = 1.25
    static let scrollSensitivity: Double = 0.04
    static let magnifySensitivity: Double = 1.5 
    static let panSpeed: Double = 5.0
    static let fitAllBuffer: Double = 3.0
}

enum TimelineAutoScroll {
    static let edgeZoneWidth: CGFloat = 56
    static let maxZoneFraction: CGFloat = 0.5
    static let minStep: CGFloat = 4
    static let maxStep: CGFloat = 28
    static let interval: TimeInterval = 1.0 / 60.0
}

enum Trim {
    static let handleWidth: CGFloat = 4.0
    static let clipCornerRadius: CGFloat = AppTheme.Radius.xsSm
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

    static var storageDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Palmier Pro", isDirectory: true)
    }

    nonisolated static func ensureStorageDirectory() {
        let url = storageDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

func gcd(_ a: Int, _ b: Int) -> Int {
    b == 0 ? a : gcd(b, a % b)
}
