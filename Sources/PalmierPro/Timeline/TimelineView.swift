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
    private static let headerBg = NSColor(white: 0.12, alpha: 1).cgColor
    private static let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: AppTheme.FontSize.sm, weight: .medium),
        .foregroundColor: AppTheme.Text.secondary,
    ]

    /// Drop target during external drags (media panel), used for drawing the insertion indicator.
    var externalDropTarget: TrackDropTarget?

    var geometry: TimelineGeometry {
        TimelineGeometry(editor: editor, bounds: bounds)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let geo = geometry

        drawTrackBackgrounds(geometry: geo, context: ctx)
        drawTrackHeaders(geometry: geo, context: ctx)

        TimelineRuler.draw(
            in: NSRect(x: geo.headerWidth, y: 0, width: Double(bounds.width) - geo.headerWidth, height: Double(geo.rulerHeight)),
            fps: editor.timeline.fps,
            pixelsPerFrame: geo.pixelsPerFrame,
            scrollOffsetX: 0,
            context: ctx
        )

        drawClips(geometry: geo, dirtyRect: bounds, context: ctx)

        if let snapX = inputController.snapIndicatorX {
            ctx.setStrokeColor(NSColor.systemYellow.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 4])
            ctx.move(to: CGPoint(x: geo.headerWidth + snapX, y: Double(geo.rulerHeight)))
            ctx.addLine(to: CGPoint(x: geo.headerWidth + snapX, y: Double(bounds.height)))
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
            ctx.move(to: CGPoint(x: geo.headerWidth, y: Double(lineY)))
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

        PlayheadRenderer.draw(
            frame: editor.currentFrame,
            pixelsPerFrame: geo.pixelsPerFrame,
            scrollOffsetX: 0,
            headerWidth: CGFloat(geo.headerWidth),
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
            let newDuration = isLeft ? drag.originalDuration - drag.deltaFrames : drag.originalDuration + drag.deltaFrames
            let delta = drag.originalStartFrame + newDuration - oldEnd
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
                        ClipRenderer.draw(clip, type: track.type, in: originalRect,
                                          isSelected: false, opacity: 0.3, context: ctx,
                                          cache: editor.mediaVisualCache)
                    }

                    let frameDelta = drag.deltaFrames
                    let trackDelta: Int = {
                        switch drag.dropTarget {
                        case .existingTrack(let idx): return idx - drag.originalTrack
                        case .newTrackAt: return 0
                        }
                    }()

                    var ghostClip = clip
                    ghostClip.startFrame = max(0, clip.startFrame + frameDelta)
                    let ghostTrack = ti + trackDelta
                    let ghostRect: NSRect
                    let ghostType: ClipType
                    if editor.timeline.tracks.indices.contains(ghostTrack) {
                        ghostRect = geo.clipRect(for: ghostClip, trackIndex: ghostTrack)
                        ghostType = editor.timeline.tracks[ghostTrack].type
                    } else {
                        ghostRect = geo.clipRect(for: ghostClip, trackIndex: ti)
                        ghostType = track.type
                    }
                    if ghostRect.intersects(dirtyRect) {
                        ClipRenderer.draw(ghostClip, type: ghostType, in: ghostRect,
                                          isSelected: true, opacity: 0.7, context: ctx,
                                          cache: editor.mediaVisualCache)
                    }
                    continue
                }

                if let (drag, isLeft) = trimDrag, clip.id == drag.clipId {
                    var previewClip = clip
                    if isLeft {
                        previewClip.trimStartFrame = drag.originalTrimStart + drag.deltaFrames
                        previewClip.durationFrames = drag.originalDuration - drag.deltaFrames
                    } else {
                        previewClip.durationFrames = drag.originalDuration + drag.deltaFrames
                    }
                    let previewRect = geo.clipRect(for: previewClip, trackIndex: ti)
                    if previewRect.intersects(dirtyRect) {
                        ClipRenderer.draw(previewClip, type: track.type, in: previewRect,
                                          isSelected: isSelected, context: ctx,
                                          cache: editor.mediaVisualCache)
                    }
                    continue
                }

                // Ripple preview: draw adjacent clips shifted
                if ripplePreview.ids.contains(clip.id) {
                    var shifted = clip
                    shifted.startFrame += ripplePreview.delta
                    let rect = geo.clipRect(for: shifted, trackIndex: ti)
                    if rect.intersects(dirtyRect) {
                        ClipRenderer.draw(shifted, type: track.type, in: rect,
                                          isSelected: isSelected, context: ctx,
                                          cache: editor.mediaVisualCache)
                    }
                    continue
                }

                // Normal clip
                let rect = geo.clipRect(for: clip, trackIndex: ti)
                guard rect.intersects(dirtyRect) else { continue }
                ClipRenderer.draw(clip, type: track.type, in: rect,
                                  isSelected: isSelected, context: ctx,
                                  cache: editor.mediaVisualCache)
            }
        }
    }

    // MARK: - Track drawing

    private func drawTrackBackgrounds(geometry geo: TimelineGeometry, context: CGContext) {
        for i in editor.timeline.tracks.indices {
            let y = geo.trackY(at: i)
            let h = geo.trackHeight(at: i)
            context.setFillColor(i % 2 == 0 ? Self.trackBgEven : Self.trackBgOdd)
            context.fill(NSRect(x: geo.headerWidth, y: y, width: bounds.width - geo.headerWidth, height: h))
        }
    }

    /// Rects for mute/hide buttons, indexed by track. Used for hit testing.
    var muteButtonRects: [Int: NSRect] = [:]
    var hideButtonRects: [Int: NSRect] = [:]

    private func drawTrackHeaders(geometry geo: TimelineGeometry, context: CGContext) {
        context.setFillColor(Self.headerBg)
        context.fill(NSRect(x: 0, y: 0, width: geo.headerWidth, height: bounds.height))

        muteButtonRects.removeAll()
        hideButtonRects.removeAll()
        let stripWidth: CGFloat = 3
        let iconSize: CGFloat = 14
        let iconConfig = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .regular)

        for (i, track) in editor.timeline.tracks.enumerated() {
            let y = geo.trackY(at: i)
            let h = geo.trackHeight(at: i)

            // Color-coded left border strip
            context.setFillColor(track.type.themeColor.cgColor)
            context.fill(NSRect(x: 0, y: y, width: stripWidth, height: h))

            // Track label (left side)
            let str = NSAttributedString(string: track.label, attributes: Self.labelAttrs)
            let labelSize = str.size()
            let labelY = y + (h - labelSize.height) / 2
            str.draw(at: NSPoint(x: stripWidth + 6, y: labelY))

            // Mute + hide buttons (right side, vertically centered)
            let iconY = y + (h - iconSize) / 2
            let hideX = geo.headerWidth - iconSize - 6
            let muteX = hideX - iconSize - 4

            let muteIcon = track.muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
            let muteTint: NSColor = track.muted ? AppTheme.Text.secondary.withAlphaComponent(0.3) : AppTheme.Text.secondary
            let muteRect = NSRect(x: muteX, y: iconY, width: iconSize, height: iconSize)
            drawSymbol(muteIcon, in: muteRect, tint: muteTint, config: iconConfig)
            muteButtonRects[i] = muteRect.insetBy(dx: -4, dy: -4)

            let hideIcon = track.hidden ? "eye.slash" : "eye"
            let hideTint: NSColor = track.hidden ? AppTheme.Text.secondary.withAlphaComponent(0.3) : AppTheme.Text.secondary
            let hideRect = NSRect(x: hideX, y: iconY, width: iconSize, height: iconSize)
            drawSymbol(hideIcon, in: hideRect, tint: hideTint, config: iconConfig)
            hideButtonRects[i] = hideRect.insetBy(dx: -4, dy: -4)

            // Resize handle at bottom of track
            let handleY = y + h - 1
            context.setFillColor(AppTheme.Border.subtle.cgColor)
            context.fill(NSRect(x: 0, y: handleY, width: geo.headerWidth, height: 1))
        }
    }

    private func drawSymbol(_ name: String, in rect: NSRect, tint: NSColor, config: NSImage.SymbolConfiguration) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let tinted = NSImage(size: rect.size, flipped: true) { drawRect in
            tint.set()
            img.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            drawRect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
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
        externalDropTarget = geometry.dropTargetAt(y: point.y)
        needsDisplay = true
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        externalDropTarget = geometry.dropTargetAt(y: point.y)
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        externalDropTarget = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let geo = geometry
        let point = convert(sender.draggingLocation, from: nil)
        let dropTarget = geo.dropTargetAt(y: point.y)
        let targetFrame = geo.frameAt(x: point.x)

        externalDropTarget = nil

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
            let matching = assets.filter { $0.type == trackType }
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
            let grouped = Dictionary(grouping: assets, by: \.type)
            let sortedTypes: [ClipType] = [.video, .image, .audio]
            editor.undoManager?.beginUndoGrouping()
            var trackOffset = 0
            for type in sortedTypes {
                guard let group = grouped[type] else { continue }
                editor.addClipsToNewTrack(assets: group, insertAt: insertIndex + trackOffset, startFrame: targetFrame)
                trackOffset += 1
            }
            editor.undoManager?.endUndoGrouping()
            editor.undoManager?.setActionName("Add Clips to New Track\(grouped.count > 1 ? "s" : "")")
        }

        needsDisplay = true
        return true
    }
}
