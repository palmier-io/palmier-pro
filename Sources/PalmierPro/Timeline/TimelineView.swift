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
        layer?.backgroundColor = AppTheme.Background.surface.cgColor
        registerForDraggedTypes([.string, .fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // Cached for draw performance — avoid per-frame allocations
    private static let trackBgEven = AppTheme.Background.surface.cgColor
    private static let trackBgOdd = AppTheme.Background.surface.cgColor

    /// Drop target during external drags (media panel), used for drawing the insertion indicator.
    var externalDropTarget: TrackDropTarget?
    /// Cached assets and drop frame during external drags, for ghost clip preview.
    var externalDragAssets: [MediaAsset]?
    var externalDragFrame: Int = 0

    private var externalSnapIndicatorX: Double?
    private var externalSnapState = SnapEngine.SnapState()

    var geometry: TimelineGeometry {
        TimelineGeometry(editor: editor, bounds: bounds)
    }

    private var isUpdatingContentSize = false

    func updateContentSize() {
        guard !isUpdatingContentSize else { return }
        isUpdatingContentSize = true
        defer { isUpdatingContentSize = false }

        guard let scrollView = enclosingScrollView else { return }
        let visibleSize = scrollView.contentView.bounds.size

        let newVisibleWidth = Double(visibleSize.width)
        if editor.timelineVisibleWidth != newVisibleWidth {
            let isFirstLayout = editor.timelineVisibleWidth == 0
            let editor = self.editor
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated {
                    editor.timelineVisibleWidth = newVisibleWidth
                    let minZoom = editor.minZoomScale
                    if isFirstLayout {
                        editor.zoomScale = editor.timeline.totalFrames == 0
                            ? Defaults.pixelsPerFrame
                            : minZoom
                    } else if editor.zoomScale < minZoom {
                        editor.zoomScale = minZoom
                    }
                }
            }
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

        if let snapX = inputController.snapIndicatorX ?? externalSnapIndicatorX {
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
            scrollOffsetY: scrollOffset.y,
            visibleHeight: enclosingScrollView?.contentView.bounds.height ?? bounds.height,
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
            return Set(drag.all.map(\.clipId))
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

        /// Linked partners that should mirror the trim preview live.
        let trimPartnerIds: Set<String> = {
            guard let (drag, _) = trimDrag, drag.propagateToLinked else { return [] }
            return Set(editor.linkedPartnerIds(of: drag.clipId))
        }()

        let linkOffsets = editor.linkGroupOffsets()

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
                    let isLead = clip.id == drag.lead.clipId

                    if isLead, case .existingTrack(let idx) = drag.dropTarget,
                       editor.timeline.tracks.indices.contains(idx) {
                        ghostRect = geo.clipRect(for: ghostClip, trackIndex: idx)
                    } else if isLead, let y = geo.ghostY(for: drag.dropTarget) {
                        ghostRect = geo.clipRect(for: ghostClip, atY: Double(y), height: Layout.trackHeight)
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

                if let (drag, isLeft) = trimDrag,
                   clip.id == drag.clipId || trimPartnerIds.contains(clip.id) {
                    var previewClip = clip
                    let sourceDelta = Int((Double(drag.deltaFrames) * clip.speed).rounded())
                    if isLeft {
                        previewClip.startFrame = clip.startFrame + drag.deltaFrames
                        previewClip.trimStartFrame = clip.trimStartFrame + sourceDelta
                        previewClip.durationFrames = clip.durationFrames - drag.deltaFrames
                    } else {
                        previewClip.durationFrames = clip.durationFrames + drag.deltaFrames
                        previewClip.trimEndFrame = clip.trimEndFrame - sourceDelta
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
                                  displayName: editor.mediaResolver.displayName(for: clip.mediaRef),
                                  linkOffset: linkOffsets[clip.id])
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
        let h = Layout.trackHeight
        let plan = editor.resolveDropPlan(cursor: target, assets: assets, atFrame: frame)

        struct Ghost {
            let clip: Clip
            let rect: NSRect
        }
        var ghosts: [Ghost] = []

        for p in plan.placements {
            if p.hasVisual, let vt = plan.visualTarget {
                let probe = Clip(mediaRef: p.asset.id, mediaType: p.asset.type, sourceClipType: p.asset.type, startFrame: p.startFrame, durationFrames: p.durationFrames)
                ghosts.append(Ghost(
                    clip: probe,
                    rect: ghostRect(target: vt, probe: probe, height: h, geo: geo)
                ))
            }
            if p.hasAudio, let at = plan.audioTarget {
                let probe = Clip(mediaRef: p.asset.id, mediaType: .audio, sourceClipType: p.asset.type, startFrame: p.startFrame, durationFrames: p.durationFrames)
                ghosts.append(Ghost(
                    clip: probe,
                    rect: ghostRect(target: at, probe: probe, height: h, geo: geo)
                ))
            }
        }

        for ghost in ghosts where ghost.rect.intersects(dirtyRect) {
            ClipRenderer.draw(ghost.clip, type: ghost.clip.mediaType, in: ghost.rect,
                              isSelected: true, opacity: 0.5, context: ctx,
                              cache: editor.mediaVisualCache)
        }
    }

    /// Geometry for a ghost rect at a given drop target
    private func ghostRect(
        target: TrackDropTarget, probe: Clip, height: CGFloat,
        geo: TimelineGeometry
    ) -> NSRect {
        switch target {
        case .existingTrack(let idx):
            return geo.clipRect(for: probe, trackIndex: idx)
        case .newTrackAt(let idx):
            let trackCount = editor.timeline.tracks.count
            let top = geo.rulerHeight + Layout.dropZoneHeight
            let y: CGFloat
            if trackCount == 0 {
                // No tracks yet — stack synthetic positions from the top by idx.
                y = top + CGFloat(idx) * height
            } else if idx >= trackCount {
                // Appending: anchor at the bottom of the last track, then step
                // down one track-height per additional slot beyond count.
                let last = trackCount - 1
                let bottom = geo.trackY(at: last) + geo.trackHeight(at: last)
                y = bottom + CGFloat(idx - trackCount) * height
            } else {
                // Inserting in the middle — ghost sits just above the insertion line.
                y = geo.trackY(at: idx) - height
            }
            return geo.clipRect(for: probe, atY: Double(y), height: height)
        }
    }

    // MARK: - Track drawing

    private func drawTrackBackgrounds(geometry geo: TimelineGeometry, context: CGContext) {
        let borderColor = AppTheme.Border.primary.cgColor
        for i in editor.timeline.tracks.indices {
            let y = geo.trackY(at: i)
            let h = geo.trackHeight(at: i)
            context.setFillColor(Self.trackBgEven)
            context.fill(NSRect(x: 0, y: y, width: bounds.width, height: h))

            // White border at top of first track and bottom of every track
            if i == 0 {
                context.setFillColor(borderColor)
                context.fill(NSRect(x: 0, y: y, width: bounds.width, height: 1))
            }
            context.setFillColor(borderColor)
            context.fill(NSRect(x: 0, y: y + h - 1, width: bounds.width, height: 1))
        }

        // Thick divider between the video zone and the audio zone.
        let z = editor.zones
        if z.videoTrackCount > 0, z.audioTrackCount > 0 {
            let dividerY = geo.trackY(at: z.firstAudioIndex)
            context.setFillColor(AppTheme.Border.divider.cgColor)
            context.fill(NSRect(x: 0, y: dividerY - 1, width: bounds.width, height: 2))
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let trackIndex = geometry.trackAt(y: point.y)
        guard let hit = inputController.hitTestClip(at: point, trackIndex: trackIndex, geometry: geometry) else {
            return nil
        }
        let clip = editor.timeline.tracks[hit.trackIndex].clips[hit.clipIndex]

        if !editor.selectedClipIds.contains(clip.id) {
            editor.selectedClipIds = editor.expandToLinkGroup([clip.id])
            needsDisplay = true
        }

        let menu = NSMenu()
        if editor.canLinkSelected {
            let item = NSMenuItem(title: "Link", action: #selector(performLink(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if editor.canUnlinkSelected {
            let item = NSMenuItem(title: "Unlink", action: #selector(performUnlink(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu.items.isEmpty ? nil : menu
    }

    @objc private func performLink(_ sender: Any?) {
        editor.linkClips(ids: editor.selectedClipIds)
        needsDisplay = true
    }

    @objc private func performUnlink(_ sender: Any?) {
        editor.unlinkClips(ids: editor.selectedClipIds)
        needsDisplay = true
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
        // Parse assets from pasteboard once on enter
        if externalDragAssets == nil, let urlString = sender.draggingPasteboard.string(forType: .string) {
            let urlStrings = urlString.split(separator: "\n").map(String.init)
            externalDragAssets = urlStrings.compactMap { str in
                editor.mediaAssets.first(where: { $0.url.absoluteString == str })
            }
        }
        externalDropTarget = geo.dropTargetAt(y: point.y)
        externalSnapState = SnapEngine.SnapState()
        externalDragFrame = applyExternalSnap(at: point, geo: geo)
        needsDisplay = true
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let geo = geometry
        externalDropTarget = geo.dropTargetAt(y: point.y)
        externalDragFrame = applyExternalSnap(at: point, geo: geo)
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        externalDropTarget = nil
        externalDragAssets = nil
        externalSnapIndicatorX = nil
        externalSnapState = SnapEngine.SnapState()
        needsDisplay = true
    }

    /// Snap the external-drag frame to clip edges / playhead
    private func applyExternalSnap(at point: NSPoint, geo: TimelineGeometry) -> Int {
        let candidate = geo.frameAt(x: point.x)
        guard let assets = externalDragAssets, !assets.isEmpty else {
            externalSnapIndicatorX = nil
            return candidate
        }
        let fps = editor.timeline.fps
        let totalDur = assets.reduce(0) { $0 + max(1, secondsToFrame(seconds: $1.duration, fps: fps)) }
        let targets = SnapEngine.collectTargets(
            tracks: editor.timeline.tracks,
            playheadFrame: editor.currentFrame,
            excludeClipIds: []
        )
        if let snap = SnapEngine.findSnap(
            position: candidate,
            probeOffsets: [0, totalDur],
            targets: targets,
            state: &externalSnapState,
            baseThreshold: Snap.thresholdPixels,
            pixelsPerFrame: geo.pixelsPerFrame
        ) {
            externalSnapIndicatorX = snap.x
            return snap.frame - snap.probeOffset
        }
        externalSnapIndicatorX = nil
        return candidate
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let geo = geometry
        let point = convert(sender.draggingLocation, from: nil)
        let cursorTarget = geo.dropTargetAt(y: point.y)
        let targetFrame = applyExternalSnap(at: point, geo: geo)

        externalDropTarget = nil
        externalDragAssets = nil
        externalSnapIndicatorX = nil
        externalSnapState = SnapEngine.SnapState()

        guard let urlString = sender.draggingPasteboard.string(forType: .string) else { return false }

        let editor = self.editor
        let urlStrings = urlString.split(separator: "\n").map(String.init)
        let assets = urlStrings.compactMap { str in
            editor.mediaAssets.first(where: { $0.url.absoluteString == str })
        }
        guard !assets.isEmpty else { return false }

        let mods = NSEvent.modifierFlags

        let operation: @MainActor () -> Void = {
            editor.undoManager?.beginUndoGrouping()

            let plan = editor.resolveDropPlan(cursor: cursorTarget, assets: assets, atFrame: targetFrame)
            let (visualIdx, audioIdx) = editor.materialize(plan: plan)
            let ripple = mods.contains(.command)

            let insert: ([MediaAsset], Int, Int?) -> Void = { assets, trackIdx, linkedAudio in
                if ripple {
                    editor.rippleInsertClips(assets: assets, trackIndex: trackIdx, atFrame: targetFrame)
                } else {
                    editor.addClips(assets: assets, trackIndex: trackIdx, startFrame: targetFrame, linkedAudioTrackIndex: linkedAudio)
                }
            }

            let visualAssets = assets.filter { $0.type.isVisual }
            if !visualAssets.isEmpty, let vIdx = visualIdx {
                insert(visualAssets, vIdx, audioIdx)
            }
            let audioOnlyAssets = assets.filter { $0.type == .audio }
            if !audioOnlyAssets.isEmpty, let aIdx = audioIdx {
                insert(audioOnlyAssets, aIdx, nil)
            }

            editor.undoManager?.endUndoGrouping()
            editor.undoManager?.setActionName("Add Clips")
        }

        editor.addClipsWithSettingsCheck(assets: assets, operation: operation)

        needsDisplay = true
        return true
    }
}
