import AppKit

enum TrackDropTarget: Equatable, Hashable {
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
        self.init(
            pixelsPerFrame: editor.zoomScale,
            headerWidth: headerWidth,
            trackHeights: editor.timeline.tracks.map(\.displayHeight),
            bounds: bounds
        )
    }

    init(pixelsPerFrame: Double, headerWidth: Double = 0, trackHeights: [CGFloat], bounds: NSRect = .zero) {
        self.pixelsPerFrame = pixelsPerFrame
        self.headerWidth = headerWidth
        self.rulerHeight = Layout.rulerHeight
        self.trackCount = trackHeights.count
        self.trackHeights = trackHeights
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

    /// Interior keyframe hit point: just pxPerFrame placement, no edge insetting.
    func audioVolumeKfPoint(clip: Clip, kfOffset: Int, kfDb: Double, in clipRect: NSRect) -> CGPoint {
        let body = ClipRenderer.clipBodyRect(in: clipRect)
        let pxPerFrame = clip.durationFrames > 0 ? clipRect.width / CGFloat(clip.durationFrames) : 0
        let x = clipRect.minX + CGFloat(kfOffset) * pxPerFrame
        return CGPoint(x: x, y: ClipRenderer.y(forDb: kfDb, in: body))
    }

    func audioVolumeKfRect(clip: Clip, kfOffset: Int, kfDb: Double, in clipRect: NSRect) -> NSRect {
        let p = audioVolumeKfPoint(clip: clip, kfOffset: kfOffset, kfDb: kfDb, in: clipRect)
        let half = ClipRenderer.volumeKeyframeHitSize / 2
        return NSRect(x: p.x - half, y: p.y - half, width: half * 2, height: half * 2)
    }

    /// Hit rect for a fade knee — sits in the fixed fade lane near the top of the body.
    func fadeKneeRect(clip: Clip, edge: FadeEdge, in clipRect: NSRect) -> NSRect {
        let body = ClipRenderer.clipBodyRect(in: clipRect)
        let pxPerFrame = clip.durationFrames > 0 ? clipRect.width / CGFloat(clip.durationFrames) : 0
        let kfOffset = edge == .left
            ? min(clip.fadeInFrames, clip.durationFrames)
            : max(0, clip.durationFrames - clip.fadeOutFrames)
        let x = ClipRenderer.fadeHandleRenderX(in: clipRect, kfOffset: kfOffset, pxPerFrame: pxPerFrame)
        let y = ClipRenderer.fadeKneeY(in: body)
        let half = ClipRenderer.volumeKeyframeHitSize / 2
        return NSRect(x: x - half, y: y - half, width: half * 2, height: half * 2)
    }
}
