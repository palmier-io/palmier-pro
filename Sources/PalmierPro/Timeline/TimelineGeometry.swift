import AppKit

/// Pure layout math for the timeline. Used by both TimelineView (drawing)
/// and TimelineInputController (hit testing).
struct TimelineGeometry {
    let pixelsPerFrame: Double
    let headerWidth: Double
    let rulerHeight: CGFloat
    let trackCount: Int
    let trackHeights: [CGFloat]
    let bounds: NSRect

    /// Precomputed cumulative Y offsets for each track (avoids O(n) per lookup).
    private let cumulativeY: [CGFloat]

    @MainActor
    init(editor: EditorViewModel, bounds: NSRect) {
        self.pixelsPerFrame = editor.zoomScale
        self.headerWidth = Layout.trackHeaderWidth
        self.rulerHeight = Layout.rulerHeight
        self.trackCount = editor.timeline.tracks.count
        self.trackHeights = editor.timeline.tracks.map(\.displayHeight)
        self.bounds = bounds

        var cumY: [CGFloat] = []
        cumY.reserveCapacity(trackHeights.count)
        var y = rulerHeight
        for h in trackHeights {
            cumY.append(y)
            y += h
        }
        self.cumulativeY = cumY
    }

    func trackHeight(at index: Int) -> CGFloat {
        trackHeights.indices.contains(index) ? trackHeights[index] : Layout.trackHeight
    }

    func trackY(at index: Int) -> CGFloat {
        cumulativeY.indices.contains(index) ? cumulativeY[index] : rulerHeight
    }

    func clipRect(for clip: Clip, trackIndex: Int) -> NSRect {
        let h = trackHeight(at: trackIndex)
        return NSRect(
            x: headerWidth + Double(clip.startFrame) * pixelsPerFrame,
            y: Double(trackY(at: trackIndex)) + 2,
            width: Double(clip.durationFrames) * pixelsPerFrame,
            height: Double(h) - 4
        )
    }

    func frameAt(x: Double) -> Int {
        max(0, Int((x - headerWidth) / pixelsPerFrame))
    }

    func trackAt(y: Double) -> Int {
        for i in cumulativeY.indices {
            if y < Double(cumulativeY[i]) + Double(trackHeights[i]) { return i }
        }
        return max(0, trackCount - 1)
    }

    func xForFrame(_ frame: Int) -> Double {
        headerWidth + Double(frame) * pixelsPerFrame
    }
}
