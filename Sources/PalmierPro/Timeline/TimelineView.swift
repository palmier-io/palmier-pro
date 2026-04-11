import AppKit

/// The core AppKit timeline view. Handles drawing only.
/// All input is delegated to TimelineInputController.
final class TimelineView: NSView {
    unowned var editor: EditorViewModel
    private(set) var inputController: TimelineInputController!

    // MARK: - Init

    init(editor: EditorViewModel) {
        self.editor = editor
        super.init(frame: .zero)
        self.inputController = TimelineInputController(editor: editor, view: self)
        editor.mediaVisualCache.timelineView = self
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        registerForDraggedTypes([.string, .fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // Cached for draw performance — avoid per-frame allocations
    private static let trackBgEven = NSColor(white: 0.17, alpha: 1).cgColor
    private static let trackBgOdd = NSColor(white: 0.14, alpha: 1).cgColor

    /// Drop target during external drags (media panel), used for drawing the insertion indicator.
    var externalDropTarget: TrackDropTarget?
    /// Cached assets and drop frame during external drags, for ghost clip preview.
    var externalDragAssets: [MediaAsset]?
    var externalDragFrame: Int = 0

    var geometry: TimelineGeometry {
        TimelineGeometry(editor: editor, bounds: bounds)
    }

    func updateContentSize() {
        guard let scrollView = enclosingScrollView else { return }
        let visibleSize = scrollView.contentView.bounds.size
        let newVisibleWidth = Double(visibleSize.width)
        if editor.timelineVisibleWidth != newVisibleWidth {
            editor.timelineVisibleWidth = newVisibleWidth
        }
        let minZoom = editor.minZoomScale
        if editor.zoomScale < minZoom {
            editor.zoomScale = minZoom
        }
        let totalFrames = editor.timeline.totalFrames
        // Add padding so user can scroll a bit past the last clip
        let contentWidth = editor.zoomScale * Double(totalFrames) + visibleSize.width * 0.5
        let geo = geometry
        let contentHeight: CGFloat
        if editor.timeline.tracks.isEmpty {
            contentHeight = visibleSize.height
        } else {
            let lastTrack = editor.timeline.tracks.count - 1
            contentHeight = max(visibleSize.height, geo.trackY(at: lastTrack) + geo.trackHeight(at: lastTrack) + Layout.dropZoneHeight)
        }
        let newSize = NSSize(width: max(visibleSize.width, contentWidth), height: contentHeight)
        if frame.size != newSize {
            setFrameSize(newSize)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let geo = geometry
        let scrollOffset = enclosingScrollView?.contentView.bounds.origin ?? .zero
        let visibleWidth = enclosingScrollView?.contentView.bounds.width ?? bounds.width

        drawTrackBackgrounds(geometry: geo, context: ctx)
        drawClips(geometry: geo, dirtyRect: bounds, context: ctx)

        if let assets = externalDragAssets, !assets.isEmpty, let target = externalDropTarget {
            drawExternalDragGhosts(assets: assets, target: target, frame: externalDragFrame, geometry: geo, dirtyRect: bounds, context: ctx)
        }

        if let snapX = inputController.snapIndicatorX {
            ctx.setStrokeColor(NSColor.systemYellow.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 4])
            ctx.move(to: CGPoint(x: snapX, y: Double(geo.rulerHeight)))
            ctx.addLine(to: CGPoint(x: snapX, y: Double(bounds.height)))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        if case .marquee(let marq) = inputController.dragState,
           marq.current.width > 0 || marq.current.height > 0 {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.1).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.addRect(marq.current)
            ctx.drawPath(using: .fillStroke)
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // Yellow insertion line for new-track drop zones
        let activeDropTarget: TrackDropTarget? = {
            if case .moveClip(let drag) = inputController.dragState {
                if case .newTrackAt = drag.dropTarget { return drag.dropTarget }
            }
            if let ext = externalDropTarget, case .newTrackAt = ext { return ext }
            return nil
        }()
        if let target = activeDropTarget, let lineY = geo.insertionLineY(for: target) {
            ctx.setStrokeColor(NSColor.systemYellow.cgColor)
            ctx.setLineWidth(2)
            ctx.move(to: CGPoint(x: 0, y: Double(lineY)))
            ctx.addLine(to: CGPoint(x: Double(bounds.width), y: Double(lineY)))
            ctx.strokePath()
        }

        if let razorFrame = inputController.razorPreviewFrame {
            let razorX = geo.xForFrame(razorFrame)
            ctx.setStrokeColor(NSColor.systemOrange.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 4])
            ctx.move(to: CGPoint(x: razorX, y: Double(geo.rulerHeight)))
            ctx.addLine(to: CGPoint(x: razorX, y: Double(bounds.height)))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        TimelineRuler.draw(
            in: NSRect(x: scrollOffset.x, y: scrollOffset.y, width: visibleWidth, height: Double(geo.rulerHeight)),
            fps: editor.timeline.fps,
            pixelsPerFrame: geo.pixelsPerFrame,
            scrollOffsetX: scrollOffset.x,
            context: ctx
        )

        PlayheadRenderer.draw(
            frame: editor.currentFrame,
            pixelsPerFrame: geo.pixelsPerFrame,
            rulerHeight: geo.rulerHeight,
            totalHeight: bounds.height,
            context: ctx
        )
    }

    // MARK: - Clip drawing with ghost support

    private func drawClips(geometry geo: TimelineGeometry, dirtyRect: NSRect, context ctx: CGContext) {
        // Determine if we're dragging a clip (for ghost rendering)
        let moveDrag: DragState.MoveClipDrag? = {
            if case .moveClip(let drag) = inputController.dragState { return drag }
            return nil
        }()

        // Determine if we're trimming (for preview rendering)
        let trimDrag: (drag: DragState.TrimDrag, isLeft: Bool)? = {
            switch inputController.dragState {
            case .trimLeft(let drag): return (drag, true)
            case .trimRight(let drag): return (drag, false)
            default: return nil
            }
        }()

        let allDraggedIds: Set<String> = {
            guard let drag = moveDrag else { return [] }
            return Set([drag.clipId] + drag.companions.map(\.clipId))
        }()

        let ripplePreview: (ids: Set<String>, delta: Int) = {
            guard let (drag, isLeft) = trimDrag, drag.deltaFrames != 0,
                  editor.timeline.tracks.indices.contains(drag.trackIndex) else { return ([], 0) }
            let oldEnd = drag.originalStartFrame + drag.originalDuration
            let newStart = isLeft ? drag.originalStartFrame + drag.deltaFrames : drag.originalStartFrame
            let newDuration = isLeft ? drag.originalDuration - drag.deltaFrames : drag.originalDuration + drag.deltaFrames
            let delta = newStart + newDuration - oldEnd
            guard delta != 0 else { return ([], 0) }
            let ids = editor.timeline.tracks[drag.trackIndex].contiguousClipIds(fromEnd: oldEnd, excludeId: drag.clipId)
            return (ids, delta)
        }()

        for (ti, track) in editor.timeline.tracks.enumerated() {
            for clip in track.clips {
                let isSelected = editor.selectedClipIds.contains(clip.id)

                if let drag = moveDrag, allDraggedIds.contains(clip.id) {
                    let originalRect = geo.clipRect(for: clip, trackIndex: ti)

                    if originalRect.intersects(dirtyRect) {
                        ClipRenderer.draw(clip, type: clip.mediaType, in: originalRect,
                                          isSelected: false, opacity: 0.3, context: ctx,
                                          cache: editor.mediaVisualCache,
                                          displayName: editor.mediaResolver.displayName(for: clip.mediaRef))
                    }

                    let frameDelta = drag.deltaFrames

                    var ghostClip = clip
                    ghostClip.startFrame = max(0, clip.startFrame + frameDelta)
                    let ghostRect: NSRect

                    if case .existingTrack(let idx) = drag.dropTarget,
                       editor.timeline.tracks.indices.contains(ti + idx - drag.originalTrack) {
                        let ghostTrack = ti + idx - drag.originalTrack
                        ghostRect = geo.clipRect(for: ghostClip, trackIndex: ghostTrack)
                    } else if let lineY = geo.insertionLineY(for: drag.dropTarget) {
                        ghostRect = geo.clipRect(for: ghostClip, atY: Double(lineY), height: Layout.trackHeight)
                    } else {
                        ghostRect = geo.clipRect(for: ghostClip, trackIndex: ti)
                    }
                    if ghostRect.intersects(dirtyRect) {
                        ClipRenderer.draw(ghostClip, type: clip.mediaType, in: ghostRect,
                                          isSelected: true, opacity: 0.7, context: ctx,
                                          cache: editor.mediaVisualCache,
                                          displayName: editor.mediaResolver.displayName(for: clip.mediaRef))
                    }
                    continue
                }

                if let (drag, isLeft) = trimDrag, clip.id == drag.clipId {
                    var previewClip = clip
                    if isLeft {
                        previewClip.startFrame = drag.originalStartFrame + drag.deltaFrames
                        previewClip.trimStartFrame = drag.originalTrimStart + drag.deltaFrames
                        previewClip.durationFrames = drag.originalDuration - drag.deltaFrames
                    } else {
                        previewClip.durationFrames = drag.originalDuration + drag.deltaFrames
                    }
                    let previewRect = geo.clipRect(for: previewClip, trackIndex: ti)
                    if previewRect.intersects(dirtyRect) {
                        ClipRenderer.draw(previewClip, type: clip.mediaType, in: previewRect,
                                          isSelected: isSelected, context: ctx,
                                          cache: editor.mediaVisualCache,
                                          displayName: editor.mediaResolver.displayName(for: clip.mediaRef))
                    }
                    continue
                }

                // Ripple preview: draw adjacent clips shifted
                if ripplePreview.ids.contains(clip.id) {
                    var shifted = clip
                    shifted.startFrame += ripplePreview.delta
                    let rect = geo.clipRect(for: shifted, trackIndex: ti)
                    if rect.intersects(dirtyRect) {
                        ClipRenderer.draw(shifted, type: clip.mediaType, in: rect,
                                          isSelected: isSelected, context: ctx,
                                          cache: editor.mediaVisualCache,
                                          displayName: editor.mediaResolver.displayName(for: clip.mediaRef))
                    }
                    continue
                }

                // Normal clip
                let rect = geo.clipRect(for: clip, trackIndex: ti)
                guard rect.intersects(dirtyRect) else { continue }
                ClipRenderer.draw(clip, type: clip.mediaType, in: rect,
                                  isSelected: isSelected, context: ctx,
                                  cache: editor.mediaVisualCache,
                                  displayName: editor.mediaResolver.displayName(for: clip.mediaRef))
            }
        }
    }

    // MARK: - External drag ghost clips

    private func drawExternalDragGhosts(
        assets: [MediaAsset],
        target: TrackDropTarget,
        frame: Int,
        geometry geo: TimelineGeometry,
        dirtyRect: NSRect,
        context ctx: CGContext
    ) {
        let fps = editor.timeline.fps

        // Groups to draw: each is (assets, type, rect-builder)
        var groups: [(assets: [MediaAsset], type: ClipType, rectFor: (Clip) -> NSRect)] = []

        switch target {
        case .existingTrack(let trackIndex):
            guard editor.timeline.tracks.indices.contains(trackIndex) else { return }
            let trackType = editor.timeline.tracks[trackIndex].type
            let matching = assets.filter { $0.type.isCompatible(with: trackType) }
            if !matching.isEmpty {
                groups.append((matching, trackType, { geo.clipRect(for: $0, trackIndex: trackIndex) }))
            }

        case .newTrackAt:
            guard let lineY = geo.insertionLineY(for: target) else { return }
            let h = Layout.trackHeight
            let visual = assets.filter { $0.type.isVisual }
            let audio = assets.filter { $0.type == .audio }
            var yOffset: CGFloat = 0
            if !visual.isEmpty {
                let y = Double(lineY) + Double(yOffset)
                groups.append((visual, .video, { geo.clipRect(for: $0, atY: y, height: h) }))
                yOffset += h
            }
            if !audio.isEmpty {
                let y = Double(lineY) + Double(yOffset)
                groups.append((audio, .audio, { geo.clipRect(for: $0, atY: y, height: h) }))
                yOffset += h
            }
        }

        for group in groups {
            var cursor = frame
            for asset in group.assets {
                let durationFrames = max(1, secondsToFrame(seconds: asset.duration, fps: fps))
                let ghostClip = Clip(mediaRef: asset.id, mediaType: asset.type, startFrame: cursor, durationFrames: durationFrames)
                let rect = group.rectFor(ghostClip)
                if rect.intersects(dirtyRect) {
                    ClipRenderer.draw(ghostClip, type: asset.type, in: rect,
                                      isSelected: true, opacity: 0.5, context: ctx,
                                      cache: editor.mediaVisualCache)
                }
                cursor += durationFrames
            }
        }
    }

    // MARK: - Track drawing

    private func drawTrackBackgrounds(geometry geo: TimelineGeometry, context: CGContext) {
        for i in editor.timeline.tracks.indices {
            let y = geo.trackY(at: i)
            let h = geo.trackHeight(at: i)
            context.setFillColor(i % 2 == 0 ? Self.trackBgEven : Self.trackBgOdd)
            context.fill(NSRect(x: 0, y: y, width: bounds.width, height: h))
        }
    }

    // MARK: - Input forwarding

    override func mouseDown(with event: NSEvent) {
        inputController.mouseDown(with: event, geometry: geometry)
    }

    override func mouseDragged(with event: NSEvent) {
        inputController.mouseDragged(with: event, geometry: geometry)
    }

    override func mouseUp(with event: NSEvent) {
        inputController.mouseUp(with: event, geometry: geometry)
    }

    override func mouseMoved(with event: NSEvent) {
        inputController.mouseMoved(with: event, geometry: geometry)
    }

    override func scrollWheel(with event: NSEvent) {
        inputController.scrollWheel(with: event, geometry: geometry)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    // MARK: - Drop target (drag from media panel)

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let geo = geometry
        externalDropTarget = geo.dropTargetAt(y: point.y)
        externalDragFrame = geo.frameAt(x: point.x)
        // Parse assets from pasteboard once on enter
        if externalDragAssets == nil, let urlString = sender.draggingPasteboard.string(forType: .string) {
            let urlStrings = urlString.split(separator: "\n").map(String.init)
            externalDragAssets = urlStrings.compactMap { str in
                editor.mediaAssets.first(where: { $0.url.absoluteString == str })
            }
        }
        needsDisplay = true
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let geo = geometry
        externalDropTarget = geo.dropTargetAt(y: point.y)
        externalDragFrame = geo.frameAt(x: point.x)
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        externalDropTarget = nil
        externalDragAssets = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let geo = geometry
        let point = convert(sender.draggingLocation, from: nil)
        let dropTarget = geo.dropTargetAt(y: point.y)
        let targetFrame = geo.frameAt(x: point.x)

        externalDropTarget = nil
        externalDragAssets = nil

        guard let urlString = sender.draggingPasteboard.string(forType: .string) else { return false }

        let urlStrings = urlString.split(separator: "\n").map(String.init)
        let assets = urlStrings.compactMap { str in
            editor.mediaAssets.first(where: { $0.url.absoluteString == str })
        }
        guard !assets.isEmpty else { return false }

        switch dropTarget {
        case .existingTrack(let targetTrack):
            guard editor.timeline.tracks.indices.contains(targetTrack) else { return false }
            let trackType = editor.timeline.tracks[targetTrack].type
            let matching = assets.filter { $0.type.isCompatible(with: trackType) }
            guard !matching.isEmpty else { return false }

            let mods = NSEvent.modifierFlags
            if mods.contains(.command) {
                editor.rippleInsertClips(assets: matching, trackIndex: targetTrack, atFrame: targetFrame)
            } else if mods.contains(.option) {
                editor.overwriteInsertClips(assets: matching, trackIndex: targetTrack, atFrame: targetFrame)
            } else {
                editor.addClips(assets: matching, trackIndex: targetTrack, startFrame: targetFrame)
            }

        case .newTrackAt(let insertIndex):
            // One track per type, deterministic order
            let visual = assets.filter { $0.type.isVisual }
            let audio = assets.filter { $0.type == .audio }
            editor.undoManager?.beginUndoGrouping()
            var trackOffset = 0
            if !visual.isEmpty {
                editor.addClipsToNewTrack(assets: visual, insertAt: insertIndex + trackOffset, startFrame: targetFrame)
                trackOffset += 1
            }
            if !audio.isEmpty {
                editor.addClipsToNewTrack(assets: audio, insertAt: insertIndex + trackOffset, startFrame: targetFrame)
                trackOffset += 1
            }
            editor.undoManager?.endUndoGrouping()
            editor.undoManager?.setActionName("Add Clips to New Track\(trackOffset > 1 ? "s" : "")")
        }

        needsDisplay = true
        return true
    }
}
