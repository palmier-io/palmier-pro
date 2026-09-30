import AppKit

enum TrackDropTarget: Equatable, Hashable {
    case existingTrack(Int)
    case newTrackAt(Int) // insert new track before this index
}

enum TimelineRowLocation: Equatable {
    case track(Int)
    case keyframeLane(trackIndex: Int, property: AnimatableProperty)
}

/// Pure layout math for the timeline. Used by both TimelineView (drawing)
/// and TimelineInputController (hit testing).
struct TimelineGeometry {
    let pixelsPerFrame: Double
    let headerWidth: Double
    var rulerHeight: CGFloat { Layout.rulerHeight }
    var trackCount: Int { trackHeights.count }
    let trackHeights: [CGFloat]
    let laneProperties: [[AnimatableProperty]]
    let bounds: NSRect

    /// Precomputed cumulative Y offsets for each track (avoids O(n) per lookup).
    private let cumulativeY: [CGFloat]
    private let blockBottoms: [CGFloat]

    @MainActor
    init(
        editor: EditorViewModel,
        bounds: NSRect,
        headerWidth: Double = 0,
        laneState: TimelineKeyframeLaneState? = nil
    ) {
        let laneProperties = editor.timeline.tracks.map { track in
            laneState?.isExpanded(trackId: track.id) == true
                ? AnimatableProperty.lanes(for: track)
                : []
        }
        self.init(
            pixelsPerFrame: editor.zoomScale,
            headerWidth: headerWidth,
            trackHeights: editor.timeline.tracks.map(\.displayHeight),
            laneProperties: laneProperties,
            bounds: bounds
        )
    }

    init(
        pixelsPerFrame: Double,
        headerWidth: Double = 0,
        trackHeights: [CGFloat],
        laneProperties: [[AnimatableProperty]] = [],
        bounds: NSRect = .zero
    ) {
        self.pixelsPerFrame = pixelsPerFrame
        self.headerWidth = headerWidth
        self.trackHeights = trackHeights
        self.laneProperties = trackHeights.indices.map { index in
            laneProperties.indices.contains(index) ? laneProperties[index] : []
        }
        self.bounds = bounds

        var cumY: [CGFloat] = []
        var bottoms: [CGFloat] = []
        cumY.reserveCapacity(trackHeights.count)
        bottoms.reserveCapacity(trackHeights.count)
        var y = Layout.rulerHeight + Layout.dropZoneHeight
        for (index, h) in trackHeights.enumerated() {
            cumY.append(y)
            y += h + CGFloat(self.laneProperties[index].count) * AppTheme.ComponentSize.timelineKeyframeLaneHeight
            bottoms.append(y)
        }
        self.cumulativeY = cumY
        self.blockBottoms = bottoms
    }

    func trackHeight(at index: Int) -> CGFloat {
        trackHeights.indices.contains(index) ? trackHeights[index] : Layout.trackHeight
    }

    func trackY(at index: Int) -> CGFloat {
        cumulativeY.indices.contains(index) ? cumulativeY[index] : rulerHeight
    }

    func trackBlockBottom(at index: Int) -> CGFloat {
        blockBottoms.indices.contains(index)
            ? blockBottoms[index]
            : trackY(at: index) + trackHeight(at: index)
    }

    var contentBottom: CGFloat {
        blockBottoms.last ?? rulerHeight + Layout.dropZoneHeight
    }

    func laneY(trackIndex: Int, property: AnimatableProperty) -> CGFloat? {
        guard laneProperties.indices.contains(trackIndex),
              let laneIndex = laneProperties[trackIndex].firstIndex(of: property) else { return nil }
        return trackY(at: trackIndex)
            + trackHeight(at: trackIndex)
            + CGFloat(laneIndex) * AppTheme.ComponentSize.timelineKeyframeLaneHeight
    }

    func laneRect(trackIndex: Int, property: AnimatableProperty) -> NSRect? {
        guard let y = laneY(trackIndex: trackIndex, property: property) else { return nil }
        return NSRect(
            x: 0,
            y: y,
            width: bounds.width,
            height: AppTheme.ComponentSize.timelineKeyframeLaneHeight
        )
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
        blockBottoms.firstIndex { y < Double($0) } ?? max(0, trackCount - 1)
    }

    func rowLocation(atY y: Double) -> TimelineRowLocation? {
        guard let trackIndex = cumulativeY.indices.first(where: {
            y >= Double(cumulativeY[$0]) && y < Double(blockBottoms[$0])
        }) else { return nil }
        let laneStart = cumulativeY[trackIndex] + trackHeights[trackIndex]
        if y < Double(laneStart) {
            return .track(trackIndex)
        }
        let laneIndex = Int((CGFloat(y) - laneStart) / AppTheme.ComponentSize.timelineKeyframeLaneHeight)
        guard laneProperties[trackIndex].indices.contains(laneIndex) else {
            return .track(trackIndex)
        }
        return .keyframeLane(
            trackIndex: trackIndex,
            property: laneProperties[trackIndex][laneIndex]
        )
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
            let bottomOfTrack = Double(blockBottoms[i])
            let topOfNext = Double(cumulativeY[i + 1])
            // The boundary region: threshold above the gap to threshold below
            if y >= bottomOfTrack - threshold && y <= topOfNext + threshold {
                return .newTrackAt(i + 1)
            }
        }

        // Bottom drop zone: past the last track
        let lastTrackBottom = Double(blockBottoms[trackCount - 1])
        if y >= lastTrackBottom {
            return .newTrackAt(trackCount)
        }

        return .existingTrack(trackAt(y: y))
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
                return blockBottoms[trackCount - 1]
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
