import AppKit
import SwiftUI

/// AppKit drawing view; input is delegated to TimelineInputController.
final class TimelineView: NSView {
    unowned var editor: EditorViewModel
    private(set) var inputController: TimelineInputController!
    private var playheadOverlay: PlayheadOverlay!
    private(set) var snapOverlay: SnapIndicatorOverlay!
    private var generatingClipOverlays: [String: NSHostingView<ClipGeneratingOverlay>] = [:]
    private var clipDisplayRects: [String: NSRect] = [:]
    private let canvas = TimelineCanvasView()

    // MARK: - Init

    init(editor: EditorViewModel) {
        self.editor = editor
        super.init(frame: .zero)
        self.inputController = TimelineInputController(editor: editor, view: self)
        editor.mediaVisualCache.timelineView = self
        wantsLayer = true
        layer?.backgroundColor = AppTheme.Background.surface.cgColor
        canvas.wantsLayer = true
        canvas.layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(canvas)
        registerForDraggedTypes([.string, .fileURL])
        playheadOverlay = PlayheadOverlay(view: self, editor: editor)
        snapOverlay = SnapIndicatorOverlay(view: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: - Viewport canvas

    // Invalidation routes to the canvas; the document view itself stays clean.
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue {
                setNeedsDisplay(bounds)
            } else {
                super.needsDisplay = newValue
            }
        }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        layoutCanvas()
        canvas.setNeedsDisplay(convert(invalidRect, to: canvas))
    }

    // Safety net for any scroll path that moves the viewport without invalidating.
    override func viewWillDraw() {
        layoutCanvas()
        super.viewWillDraw()
    }

    private func layoutCanvas() {
        let target = visibleRect
        guard !target.isEmpty, canvas.frame != target else { return }
        canvas.frame = target
        canvas.needsDisplay = true
    }

    // Cached for draw performance — avoid per-frame allocations.
    private static let trackBg = AppTheme.Background.surface.cgColor

    var externalDropTarget: TrackDropTarget?
    var externalDragAssets: [MediaAsset]?
    var externalDragFrame: Int = 0

    private var externalSnapState = SnapEngine.SnapState()

    private var externalDragIsRippleInsert: Bool = false

    var geometry: TimelineGeometry {
        TimelineGeometry(editor: editor, bounds: bounds)
    }

    private var isUpdatingContentSize = false

    // Nil until first layout; used to detect playhead-anchored zoom changes.
    private var lastAppliedZoomScale: Double?

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

        if let previousZoom = lastAppliedZoomScale, previousZoom != editor.zoomScale {
            applyPlayheadAnchoredScroll(previousZoom: previousZoom, scrollView: scrollView)
        }
        lastAppliedZoomScale = editor.zoomScale
        layoutCanvas()
    }

    func markZoomApplied() {
        lastAppliedZoomScale = editor.zoomScale
    }

    @discardableResult
    func autoScrollHorizontallyForTimelineDrag(windowPoint: NSPoint) -> Bool {
        guard let scrollView = enclosingScrollView else { return false }
        let visibleRect = scrollView.contentView.bounds
        guard visibleRect.width > 0 else { return false }

        let delta = horizontalAutoScrollDelta(windowPoint: windowPoint, visibleRect: visibleRect)
        guard delta != 0 else { return false }

        let maxX = max(0, bounds.width - visibleRect.width)
        let nextX = min(maxX, max(0, visibleRect.origin.x + delta))
        guard nextX != visibleRect.origin.x else { return false }

        scrollView.contentView.setBoundsOrigin(NSPoint(x: nextX, y: visibleRect.origin.y))
        return true
    }

    private func horizontalAutoScrollDelta(windowPoint: NSPoint, visibleRect: NSRect) -> CGFloat {
        let point = convert(windowPoint, from: nil)
        let zone = min(TimelineAutoScroll.edgeZoneWidth, visibleRect.width * TimelineAutoScroll.maxZoneFraction)
        guard zone > 0 else { return 0 }

        if point.x < visibleRect.minX + zone {
            let distance = visibleRect.minX + zone - point.x
            return -horizontalAutoScrollStep(distance: distance, zone: zone)
        }
        if point.x > visibleRect.maxX - zone {
            let distance = point.x - (visibleRect.maxX - zone)
            return horizontalAutoScrollStep(distance: distance, zone: zone)
        }
        return 0
    }

    private func horizontalAutoScrollStep(distance: CGFloat, zone: CGFloat) -> CGFloat {
        let progress = min(1, max(0, distance / zone))
        return TimelineAutoScroll.minStep + (TimelineAutoScroll.maxStep - TimelineAutoScroll.minStep) * progress
    }

    private func applyPlayheadAnchoredScroll(previousZoom: Double, scrollView: NSScrollView) {
        let origin = scrollView.contentView.bounds.origin
        let visibleWidth = scrollView.contentView.bounds.size.width
        guard visibleWidth > 0 else { return }

        let playheadPrevX = Double(editor.activeFrame) * previousZoom
        let anchorViewportX: Double
        if playheadPrevX >= origin.x, playheadPrevX <= origin.x + visibleWidth {
            anchorViewportX = playheadPrevX - origin.x
        } else {
            anchorViewportX = visibleWidth * 0.5
        }
        let playheadNewX = Double(editor.activeFrame) * editor.zoomScale
        let newScrollX = max(0, playheadNewX - anchorViewportX)
        guard newScrollX != origin.x else { return }
        scrollView.contentView.setBoundsOrigin(NSPoint(x: newScrollX, y: origin.y))
    }

    // MARK: - Drawing

    /// Draws in document coordinates; the canvas translates its context before calling.
    fileprivate func drawContent(in dirtyRect: NSRect, context ctx: CGContext) {
        let geo = geometry
        let scrollOffset = enclosingScrollView?.contentView.bounds.origin ?? .zero
        let visibleWidth = enclosingScrollView?.contentView.bounds.width ?? bounds.width

        drawTrackBackgrounds(geometry: geo, context: ctx)
        drawTimelineRangeSelectionTrackFill(geometry: geo, context: ctx)
        drawClips(geometry: geo, dirtyRect: dirtyRect, context: ctx)
        drawGapSelection(geometry: geo, context: ctx)
        syncGeneratingClipOverlays(geometry: geo)

        if let assets = externalDragAssets, !assets.isEmpty, let target = externalDropTarget {
            drawExternalDragGhosts(assets: assets, target: target, frame: externalDragFrame, geometry: geo, dirtyRect: bounds, context: ctx)
            if externalDragIsRippleInsert {
                drawRippleInsertIndicator(atFrame: externalDragFrame, geometry: geo, context: ctx)
            }
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
        drawTimelineRangeSelectionRulerFill(geometry: geo, scrollOffset: scrollOffset, context: ctx)
        drawTimelineRangeSelectionEdges(geometry: geo, scrollOffset: scrollOffset, context: ctx)
    }

    func updatePlayheadLayer() { playheadOverlay.update() }

    // MARK: - Clip drawing with ghost support

    private func drawClips(geometry geo: TimelineGeometry, dirtyRect: NSRect, context ctx: CGContext) {
        let moveDrag: DragState.MoveClipDrag? = {
            if case .moveClip(let drag) = inputController.dragState { return drag }
            return nil
        }()

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

        let moveTrackDelta = moveDrag?.trackDelta ?? 0
        let movePinnedIds = moveDrag.map(inputController.pinnedCompanionIds(for:)) ?? []

        let trimPartnerIds: Set<String> = {
            guard let (drag, _) = trimDrag, drag.propagateToLinked else { return [] }
            return Set(editor.linkedPartnerIds(of: drag.clipId))
        }()

        let linkOffsets = editor.linkGroupOffsets()

        clipDisplayRects.removeAll(keepingCapacity: true)
        for (ti, track) in editor.timeline.tracks.enumerated() {
            for clip in track.clips {
                let isSelected = editor.selectedClipIds.contains(clip.id)
                let clipMissing = editor.isClipMediaMissing(clip)
                let clipGenerating = editor.isClipMediaGenerating(clip)

                if let drag = moveDrag, allDraggedIds.contains(clip.id) {
                    let originalRect = geo.clipRect(for: clip, trackIndex: ti)

                    if originalRect.intersects(dirtyRect) {
                        let originalOpacity = drag.isDuplicate ? 1.0 : 0.3
                        ClipRenderer.draw(clip, type: clip.mediaType, in: originalRect,
                                          isSelected: drag.isDuplicate && isSelected, opacity: originalOpacity, context: ctx,
                                          cache: editor.mediaVisualCache,
                                          displayName: editor.clipDisplayLabel(for: clip),
                                          fps: editor.timeline.fps, isMissing: clipMissing, isGenerating: clipGenerating)
                    }

                    let frameDelta = drag.deltaFrames

                    var ghostClip = clip
                    ghostClip.startFrame = max(0, clip.startFrame + frameDelta)
                    let isPinned = movePinnedIds.contains(clip.id)
                    let onLeadRow = ti == drag.lead.originalTrack

                    let ghostRect: NSRect
                    if case .newTrackAt = drag.dropTarget,
                       !isPinned, onLeadRow,
                       let y = geo.ghostY(for: drag.dropTarget) {
                        ghostRect = geo.clipRect(for: ghostClip, atY: Double(y), height: Layout.trackHeight)
                    } else {
                        let destTrack = isPinned ? ti : ti + moveTrackDelta
                        ghostRect = geo.clipRect(for: ghostClip, trackIndex: destTrack)
                    }
                    clipDisplayRects[clip.id] = ghostRect
                    if ghostRect.intersects(dirtyRect) {
                        ClipRenderer.draw(ghostClip, type: clip.mediaType, in: ghostRect,
                                          isSelected: true, opacity: 0.7, context: ctx,
                                          cache: editor.mediaVisualCache,
                                          displayName: editor.clipDisplayLabel(for: clip),
                                          fps: editor.timeline.fps, isMissing: clipMissing, isGenerating: clipGenerating)
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
                    clipDisplayRects[clip.id] = previewRect
                    if previewRect.intersects(dirtyRect) {
                        ClipRenderer.draw(previewClip, type: clip.mediaType, in: previewRect,
                                          isSelected: isSelected, context: ctx,
                                          cache: editor.mediaVisualCache,
                                          displayName: editor.clipDisplayLabel(for: clip),
                                          fps: editor.timeline.fps, isMissing: clipMissing, isGenerating: clipGenerating)
                    }
                    continue
                }

                let rect = geo.clipRect(for: clip, trackIndex: ti)
                clipDisplayRects[clip.id] = rect
                guard rect.intersects(dirtyRect) else { continue }
                ClipRenderer.draw(clip, type: clip.mediaType, in: rect,
                                  isSelected: isSelected, context: ctx,
                                  cache: editor.mediaVisualCache,
                                  displayName: editor.clipDisplayLabel(for: clip),
                                  linkOffset: linkOffsets[clip.id],
                                  fps: editor.timeline.fps, isMissing: clipMissing, isGenerating: clipGenerating)
            }
        }
    }

    // MARK: - Gap selection

    private func drawTimelineRangeSelectionTrackFill(geometry geo: TimelineGeometry, context ctx: CGContext) {
        guard let range = editor.validSelectedTimelineRange else { return }
        let minX = geo.xForFrame(range.startFrame)
        let maxX = geo.xForFrame(range.endFrame)
        let rect = NSRect(
            x: minX,
            y: Double(geo.rulerHeight),
            width: maxX - minX,
            height: max(0, Double(bounds.height - geo.rulerHeight))
        )
        ctx.setFillColor(AppTheme.Text.primary.withAlphaComponent(AppTheme.Opacity.hint).cgColor)
        ctx.fill(rect)
    }

    private func drawTimelineRangeSelectionRulerFill(
        geometry geo: TimelineGeometry,
        scrollOffset: NSPoint,
        context ctx: CGContext
    ) {
        guard let range = editor.validSelectedTimelineRange else { return }
        let minX = geo.xForFrame(range.startFrame)
        let maxX = geo.xForFrame(range.endFrame)
        let rulerRect = NSRect(
            x: minX,
            y: scrollOffset.y,
            width: maxX - minX,
            height: Double(geo.rulerHeight)
        )

        ctx.setFillColor(AppTheme.Text.primary.withAlphaComponent(AppTheme.Opacity.soft).cgColor)
        ctx.fill(rulerRect)
    }

    private func drawTimelineRangeSelectionEdges(
        geometry geo: TimelineGeometry,
        scrollOffset: NSPoint,
        context ctx: CGContext
    ) {
        guard let range = editor.validSelectedTimelineRange else { return }
        let minX = geo.xForFrame(range.startFrame)
        let maxX = geo.xForFrame(range.endFrame)

        ctx.setStrokeColor(AppTheme.Accent.timecodeNSColor.withAlphaComponent(AppTheme.Opacity.prominent).cgColor)
        ctx.setLineWidth(AppTheme.BorderWidth.medium)
        for x in [minX, maxX] {
            ctx.move(to: CGPoint(x: x, y: Double(scrollOffset.y)))
            ctx.addLine(to: CGPoint(x: x, y: Double(scrollOffset.y + geo.rulerHeight)))
        }
        ctx.strokePath()
    }

    private func drawGapSelection(geometry geo: TimelineGeometry, context ctx: CGContext) {
        guard let gap = editor.selectedGap,
              editor.timeline.tracks.indices.contains(gap.trackIndex) else { return }
        let y = Double(geo.trackY(at: gap.trackIndex))
        let height = Double(geo.trackHeight(at: gap.trackIndex))
        let minX = geo.xForFrame(gap.range.start)
        let maxX = geo.xForFrame(gap.range.end)
        let rect = NSRect(x: minX, y: y + 2, width: maxX - minX, height: height - 4)

        ctx.setFillColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.addRect(rect.insetBy(dx: 0.5, dy: 0.5))
        ctx.drawPath(using: .fillStroke)
        ctx.setLineDash(phase: 0, lengths: [])
    }

    // MARK: - Generating clip overlays

    private func syncGeneratingClipOverlays(geometry geo: TimelineGeometry) {
        var active: [String: NSRect] = [:]
        for (ti, track) in editor.timeline.tracks.enumerated() {
            for clip in track.clips
                where editor.pendingReplacements.contains(clip.id) || editor.isClipMediaGenerating(clip) {
                active[clip.id] = clipDisplayRects[clip.id] ?? geo.clipRect(for: clip, trackIndex: ti)
            }
        }

        for (clipId, view) in generatingClipOverlays where active[clipId] == nil {
            view.removeFromSuperview()
            generatingClipOverlays.removeValue(forKey: clipId)
        }

        for (clipId, rect) in active {
            let view = generatingClipOverlays[clipId] ?? makeGeneratingClipOverlay(for: clipId)
            if view.frame != rect { view.frame = rect }
        }
    }

    private func makeGeneratingClipOverlay(for clipId: String) -> NSHostingView<ClipGeneratingOverlay> {
        let view = NSHostingView(rootView: ClipGeneratingOverlay())
        view.autoresizingMask = []
        addSubview(view)
        generatingClipOverlays[clipId] = view
        return view
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
                              cache: editor.mediaVisualCache,
                              fps: editor.timeline.fps,
                              isMissing: editor.isClipMediaMissing(ghost.clip),
                              isGenerating: editor.isClipMediaGenerating(ghost.clip))
        }
    }

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
                y = top + CGFloat(idx) * height
            } else if idx >= trackCount {
                let last = trackCount - 1
                let bottom = geo.trackY(at: last) + geo.trackHeight(at: last)
                y = bottom + CGFloat(idx - trackCount) * height
            } else {
                y = geo.trackY(at: idx) - height
            }
            return geo.clipRect(for: probe, atY: Double(y), height: height)
        }
    }

    // MARK: - Ripple-insert indicator

    private func drawRippleInsertIndicator(atFrame frame: Int, geometry geo: TimelineGeometry, context ctx: CGContext) {
        let x = geo.xForFrame(frame)
        let top = Double(geo.rulerHeight)
        let bottom = Double(bounds.height)

        let color = NSColor.white.cgColor
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: x, y: top))
        ctx.addLine(to: CGPoint(x: x, y: bottom))
        ctx.strokePath()

        let arrowW: CGFloat = 7
        let arrowH: CGFloat = 10
        ctx.move(to: CGPoint(x: x, y: top))
        ctx.addLine(to: CGPoint(x: x + arrowW, y: top + Double(arrowH) / 2))
        ctx.addLine(to: CGPoint(x: x, y: top + Double(arrowH)))
        ctx.closePath()
        ctx.fillPath()
    }

    // MARK: - Track drawing

    private func drawTrackBackgrounds(geometry geo: TimelineGeometry, context: CGContext) {
        let borderColor = AppTheme.Border.primary.cgColor
        for i in editor.timeline.tracks.indices {
            let y = geo.trackY(at: i)
            let h = geo.trackHeight(at: i)
            context.setFillColor(Self.trackBg)
            context.fill(NSRect(x: 0, y: y, width: bounds.width, height: h))

            if i == 0 {
                context.setFillColor(borderColor)
                context.fill(NSRect(x: 0, y: y, width: bounds.width, height: 1))
            }
            context.setFillColor(borderColor)
            context.fill(NSRect(x: 0, y: y + h - 1, width: bounds.width, height: 1))
        }

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

    override func magnify(with event: NSEvent) {
        inputController.magnify(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let trackIndex = geometry.trackAt(y: point.y)
        let clickFrame = max(0, geometry.frameAt(x: point.x))
        let clickedRange = editor.validSelectedTimelineRange?.contains(frame: clickFrame) ?? false
        guard let hit = inputController.hitTestClip(at: point, trackIndex: trackIndex, geometry: geometry) else {
            return emptyAreaMenu(trackIndex: trackIndex, frame: clickFrame, clickedRange: clickedRange)
        }
        let clip = editor.timeline.tracks[hit.trackIndex].clips[hit.clipIndex]
        let clipRect = geometry.clipRect(for: clip, trackIndex: hit.trackIndex)

        if let edge = inputController.fadeKneeHit(at: point, clip: clip, clipRect: clipRect) {
            let menu = NSMenu()
            let current = clip.fadeInterpolation(edge)
            let mk: (String, Interpolation) -> NSMenuItem = { title, interp in
                let item = NSMenuItem(title: title, action: #selector(self.performSetFadeInterpolation(_:)), keyEquivalent: "")
                item.target = self
                item.state = current == interp ? .on : .off
                item.representedObject = [
                    "clipId": clip.id,
                    "edgeIsLeft": edge == .left,
                    "interp": interp.rawValue
                ] as [String: Any]
                return item
            }
            menu.addItem(mk("Linear", .linear))
            menu.addItem(mk("Smooth", .smooth))
            return menu
        }

        // kf menu before clip menu.
        if clip.mediaType == .audio,
           let kfFrame = inputController.audioVolumeKfHit(at: point, clip: clip, clipRect: clipRect) {
            let menu = NSMenu()
            let current = editor.interpolation(clipId: clip.id, property: .volume, atFrame: kfFrame) ?? .smooth
            let mk: (String, Interpolation) -> NSMenuItem = { title, interp in
                let item = NSMenuItem(title: title, action: #selector(self.performSetVolumeKfInterpolation(_:)), keyEquivalent: "")
                item.target = self
                item.state = current == interp ? .on : .off
                item.representedObject = ["clipId": clip.id, "frame": kfFrame, "interp": interp.rawValue] as [String: Any]
                return item
            }
            menu.addItem(mk("Linear", .linear))
            menu.addItem(mk("Smooth", .smooth))
            menu.addItem(mk("Hold", .hold))
            menu.addItem(.separator())
            let del = NSMenuItem(title: "Delete Keyframe", action: #selector(performDeleteVolumeKf(_:)), keyEquivalent: "")
            del.target = self
            del.representedObject = ["clipId": clip.id, "frame": kfFrame] as [String: Any]
            menu.addItem(del)
            return menu
        }

        if !editor.selectedClipIds.contains(clip.id) {
            editor.selectedClipIds = editor.expandToLinkGroup([clip.id])
            needsDisplay = true
        }

        let menu = NSMenu()
        let targetClipIds = selectedClipIdsInTimelineOrder()

        let addToChatItem = NSMenuItem(title: "Add to Chat", action: #selector(performAddClipsToChat(_:)), keyEquivalent: "")
        addToChatItem.target = self
        addToChatItem.representedObject = targetClipIds
        menu.addItem(addToChatItem)
        menu.addItem(.separator())

        let copyItem = NSMenuItem(title: "Copy", action: #selector(performCopyClips(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        if editor.canPasteClips {
            let pasteItem = NSMenuItem(title: "Paste", action: #selector(performPasteClips(_:)), keyEquivalent: "")
            pasteItem.target = self
            pasteItem.representedObject = ["trackIndex": hit.trackIndex, "frame": clickFrame] as [String: Any]
            menu.addItem(pasteItem)
        }

        if clip.mediaType != .text, editor.selectedClipIds == editor.expandToLinkGroup([clip.id]) {
            menu.addItem(.separator())
            let swapItem = NSMenuItem(title: "Swap Media", action: #selector(performSwapMedia(_:)), keyEquivalent: "")
            swapItem.target = self
            swapItem.representedObject = clip.id
            menu.addItem(swapItem)
        }

        if clip.mediaType == .video || clip.mediaType == .audio {
            menu.addItem(.separator())
            let item = NSMenuItem(
                title: "Save as Media",
                action: #selector(performSaveAsMedia(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = clip.id
            menu.addItem(item)
        }
        if editor.canLinkSelected {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Link", action: #selector(performLink(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if editor.canUnlinkSelected {
            if !editor.canLinkSelected { menu.addItem(.separator()) }
            let item = NSMenuItem(title: "Unlink", action: #selector(performUnlink(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if clickedRange {
            menu.addItem(.separator())
            addTimelineRangeItems(to: menu)
        }
        return menu.items.isEmpty ? nil : menu
    }

    private func emptyAreaMenu(trackIndex: Int, frame: Int, clickedRange: Bool) -> NSMenu? {
        let menu = NSMenu()
        if editor.canPasteClips,
           editor.timeline.tracks.indices.contains(trackIndex) {
            let item = NSMenuItem(title: "Paste", action: #selector(performPasteClips(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["trackIndex": trackIndex, "frame": frame] as [String: Any]
            menu.addItem(item)
        }
        if clickedRange {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            addTimelineRangeItems(to: menu)
        }
        guard !menu.items.isEmpty else { return nil }
        return menu
    }

    private func addTimelineRangeItems(to menu: NSMenu) {
        let addItem = NSMenuItem(title: "Add Range to Chat", action: #selector(performAddTimelineRangeToChat(_:)), keyEquivalent: "")
        addItem.target = self
        menu.addItem(addItem)
        addClearRangeItem(to: menu)
    }

    private func addClearRangeItem(to menu: NSMenu) {
        let item = NSMenuItem(title: "Clear Range", action: #selector(performClearTimelineRange(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func selectedClipIdsInTimelineOrder() -> [String] {
        let selected = editor.selectedClipIds
        return editor.timeline.tracks.flatMap(\.clips).compactMap { clip in
            selected.contains(clip.id) ? clip.id : nil
        }
    }

    @objc private func performAddClipsToChat(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let clipIds = item.representedObject as? [String] else { return }
        editor.agentService.attachMentions(forClipIds: clipIds)
    }

    @objc private func performAddTimelineRangeToChat(_ sender: Any?) {
        editor.agentService.attachSelectedTimelineRangeMention()
    }

    @objc private func performClearTimelineRange(_ sender: Any?) {
        editor.clearTimelineRange()
        needsDisplay = true
    }

    @objc private func performCopyClips(_ sender: Any?) {
        editor.copySelectedClipsToClipboard()
    }

    @objc private func performPasteClips(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let info = item.representedObject as? [String: Any],
              let trackIndex = info["trackIndex"] as? Int,
              let frame = info["frame"] as? Int else { return }
        editor.pasteClips(atTrack: trackIndex, atFrame: frame)
        needsDisplay = true
    }

    @objc private func performLink(_ sender: Any?) {
        editor.linkClips(ids: editor.selectedClipIds)
        needsDisplay = true
    }

    @objc private func performUnlink(_ sender: Any?) {
        editor.unlinkClips(ids: editor.selectedClipIds)
        needsDisplay = true
    }

    @objc private func performSaveAsMedia(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let clipId = item.representedObject as? String else { return }
        editor.saveClipAsMedia(clipId: clipId)
    }

    @objc private func performSwapMedia(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let clipId = item.representedObject as? String else { return }
        editor.beginMediaSwap(clipId: clipId)
    }

    @objc private func performSetVolumeKfInterpolation(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let info = item.representedObject as? [String: Any],
              let clipId = info["clipId"] as? String,
              let frame = info["frame"] as? Int,
              let raw = info["interp"] as? String,
              let interp = Interpolation(rawValue: raw) else { return }
        editor.setInterpolation(clipId: clipId, property: .volume, frame: frame, interpolation: interp)
        needsDisplay = true
    }

    @objc private func performSetFadeInterpolation(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let info = item.representedObject as? [String: Any],
              let clipId = info["clipId"] as? String,
              let edgeIsLeft = info["edgeIsLeft"] as? Bool,
              let raw = info["interp"] as? String,
              let interp = Interpolation(rawValue: raw) else { return }
        editor.setFadeInterpolation(clipId: clipId, edge: edgeIsLeft ? .left : .right, interpolation: interp)
        needsDisplay = true
    }

    @objc private func performDeleteVolumeKf(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let info = item.representedObject as? [String: Any],
              let clipId = info["clipId"] as? String,
              let frame = info["frame"] as? Int else { return }
        editor.removeKeyframe(clipId: clipId, property: .volume, at: frame)
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
        if externalDragAssets == nil, let urlString = sender.draggingPasteboard.string(forType: .string) {
            externalDragAssets = editor.assetsFromDragPayload(urlString)
        }
        externalDropTarget = geo.dropTargetAt(y: point.y)
        externalSnapState = SnapEngine.SnapState()
        externalDragFrame = applyExternalSnap(at: point, geo: geo)
        externalDragIsRippleInsert = NSEvent.modifierFlags.contains(.command)
        needsDisplay = true
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let geo = geometry
        externalDropTarget = geo.dropTargetAt(y: point.y)
        externalDragFrame = applyExternalSnap(at: point, geo: geo)
        externalDragIsRippleInsert = NSEvent.modifierFlags.contains(.command)
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        externalDropTarget = nil
        externalDragAssets = nil
        snapOverlay.setExternalX(nil)
        externalSnapState = SnapEngine.SnapState()
        externalDragIsRippleInsert = false
        needsDisplay = true
    }

    private func applyExternalSnap(at point: NSPoint, geo: TimelineGeometry) -> Int {
        let candidate = geo.frameAt(x: point.x)
        guard let assets = externalDragAssets, !assets.isEmpty else {
            snapOverlay.setExternalX(nil)
            return candidate
        }
        let fps = editor.timeline.fps
        let totalDur = assets.reduce(0) { $0 + max(1, secondsToFrame(seconds: $1.duration, fps: fps)) }
        let targets = SnapEngine.collectTargets(
            tracks: editor.timeline.tracks
        )
        if let snap = SnapEngine.findSnap(
            position: candidate,
            probeOffsets: [0, totalDur],
            targets: targets,
            state: &externalSnapState,
            baseThreshold: Snap.thresholdPixels,
            pixelsPerFrame: geo.pixelsPerFrame
        ) {
            snapOverlay.setExternalX(snap.x)
            return snap.frame - snap.probeOffset
        }
        snapOverlay.setExternalX(nil)
        return candidate
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let geo = geometry
        let point = convert(sender.draggingLocation, from: nil)
        let cursorTarget = geo.dropTargetAt(y: point.y)
        let targetFrame = applyExternalSnap(at: point, geo: geo)

        externalDropTarget = nil
        externalDragAssets = nil
        snapOverlay.setExternalX(nil)
        externalSnapState = SnapEngine.SnapState()
        externalDragIsRippleInsert = false

        guard let urlString = sender.draggingPasteboard.string(forType: .string) else { return false }

        let editor = self.editor
        let assets = editor.assetsFromDragPayload(urlString)
        let segments = editor.segmentsFromDragPayload(urlString)
        guard !assets.isEmpty else { return false }

        let mods = NSEvent.modifierFlags

        let operation: @MainActor () -> Void = {
            editor.undoManager?.beginUndoGrouping()

            let plan = editor.resolveDropPlan(cursor: cursorTarget, assets: assets, atFrame: targetFrame)
            let (visualIdx, audioIdx) = editor.materialize(plan: plan)
            let ripple = mods.contains(.command)

            let insert: ([MediaAsset], Int, Int?) -> Void = { assets, trackIdx, linkedAudio in
                if ripple {
                    editor.rippleInsertClips(assets: assets, trackIndex: trackIdx, atFrame: targetFrame, segments: segments)
                } else {
                    editor.addClips(assets: assets, trackIndex: trackIdx, startFrame: targetFrame, linkedAudioTrackIndex: linkedAudio, segments: segments)
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

/// Viewport-sized drawing surface; transparent to hit testing so all input
/// reaches the TimelineView document view in document coordinates.
private final class TimelineCanvasView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let timeline = superview as? TimelineView else { return }
        let origin = frame.origin
        ctx.translateBy(x: -origin.x, y: -origin.y)
        timeline.drawContent(in: dirtyRect.offsetBy(dx: origin.x, dy: origin.y), context: ctx)
    }
}
