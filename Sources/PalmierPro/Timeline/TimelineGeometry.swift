import AppKit

enum TrackDropTarget: Equatable {
    case existingTrack(Int)
    case newTrackAt(Int) // insert new track before this index
}

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
    init(editor: EditorViewModel, bounds: NSRect, headerWidth: Double = 0) {
        self.pixelsPerFrame = editor.zoomScale
        self.headerWidth = headerWidth
        self.rulerHeight = Layout.rulerHeight
        self.trackCount = editor.timeline.tracks.count
        self.trackHeights = editor.timeline.tracks.map(\.displayHeight)
        self.bounds = bounds

        var cumY: [CGFloat] = []
        cumY.reserveCapacity(trackHeights.count)
        var y = rulerHeight + Layout.dropZoneHeight
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
        clipRect(for: clip, atY: Double(trackY(at: trackIndex)), height: Double(trackHeight(at: trackIndex)))
    }

    /// Clip rect at an arbitrary Y position (used for ghost clips at insertion lines).
    func clipRect(for clip: Clip, atY y: Double, height h: Double) -> NSRect {
        NSRect(
            x: headerWidth + Double(clip.startFrame) * pixelsPerFrame,
            y: y + 2,
            width: Double(clip.durationFrames) * pixelsPerFrame,
            height: h - 4
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

    func dropTargetAt(y: Double) -> TrackDropTarget {
        guard trackCount > 0 else { return .newTrackAt(0) }

        // Top drop zone
        if y < Double(cumulativeY[0]) {
            return .newTrackAt(0)
        }

        // Check between-track boundaries
        let threshold = Double(Layout.insertThreshold)
        for i in 0..<(trackCount - 1) {
            let bottomOfTrack = Double(cumulativeY[i]) + Double(trackHeights[i])
            let topOfNext = Double(cumulativeY[i + 1])
            // The boundary region: threshold above the gap to threshold below
            if y >= bottomOfTrack - threshold && y <= topOfNext + threshold {
                return .newTrackAt(i + 1)
            }
        }

        // Bottom drop zone: past the last track
        let lastTrackBottom = Double(cumulativeY[trackCount - 1]) + Double(trackHeights[trackCount - 1])
        if y >= lastTrackBottom {
            return .newTrackAt(trackCount)
        }

        // On an existing track
        for i in cumulativeY.indices {
            if y < Double(cumulativeY[i]) + Double(trackHeights[i]) { return .existingTrack(i) }
        }
        return .existingTrack(max(0, trackCount - 1))
    }

    func insertionLineY(for target: TrackDropTarget) -> CGFloat? {
        switch target {
        case .existingTrack:
            return nil
        case .newTrackAt(let index):
            if trackCount == 0 {
                return rulerHeight + Layout.dropZoneHeight
            } else if index == 0 {
                return cumulativeY[0]
            } else if index >= trackCount {
                return cumulativeY[trackCount - 1] + trackHeights[trackCount - 1]
            } else {
                return cumulativeY[index]
            }
        }
    }

    /// Y position where a ghost clip should render for a new-track drop.
    func ghostY(for target: TrackDropTarget, height: CGFloat = Layout.trackHeight) -> CGFloat? {
        guard case .newTrackAt(let index) = target,
              let lineY = insertionLineY(for: target) else { return nil }
        return index < trackCount ? lineY - height : lineY
    }

    func xForFrame(_ frame: Int) -> Double {
        headerWidth + Double(frame) * pixelsPerFrame
    }

    /// Centerline X of an audio fade handle
    static func audioFadeHandleX(in clipRect: NSRect, fadeFrames: Int, edge: FadeEdge, pxPerFrame: CGFloat) -> CGFloat {
        let fadePx = CGFloat(fadeFrames) * pxPerFrame
        let inset = ClipRenderer.fadeHandleEdgeInset
        let knee = max(inset, min(max(inset, clipRect.width - inset), fadePx))
        return edge == .left ? clipRect.minX + knee : clipRect.maxX - knee
    }

    /// Hit rect for an audio fade handle
    func audioFadeHandleRect(in clipRect: NSRect, fadeFrames: Int, edge: FadeEdge) -> NSRect {
        let cx = Self.audioFadeHandleX(in: clipRect, fadeFrames: fadeFrames, edge: edge, pxPerFrame: pixelsPerFrame)
        let cy = clipRect.minY + ClipRenderer.labelBarHeight
        let half = ClipRenderer.fadeHandleHitSize / 2
        return NSRect(x: cx - half, y: cy - half, width: half * 2, height: half * 2)
    }
}
