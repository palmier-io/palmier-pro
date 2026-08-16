import SwiftUI

enum TimelineHeaderSymbol {
    static func image(
        named name: String,
        tint: NSColor,
        configuration: NSImage.SymbolConfiguration
    ) -> NSImage? {
        let colorConfiguration = NSImage.SymbolConfiguration(paletteColors: [tint, tint, tint])
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration.applying(colorConfiguration))
    }
}

/// Resizable track header column drawn to the left of the scrollable timeline.
final class TimelineHeaderView: NSView {
    unowned var editor: EditorViewModel
    let keyframeLaneState: TimelineKeyframeLaneState

    var requestCanvasRedraw: (() -> Void)?

    private static var headerBg: CGColor { AppTheme.Background.surface.cgColor }
    private static let labelFont = NSFont.systemFont(ofSize: AppTheme.FontSize.sm, weight: .medium)
    private var labelAttrs: [NSAttributedString.Key: Any] = [:]

    /// Track-header button hit areas indexed by track.
    var muteButtonRects: [Int: NSRect] = [:]
    var hideButtonRects: [Int: NSRect] = [:]
    var syncLockButtonRects: [Int: NSRect] = [:]
    var keyframeButtonRects: [Int: NSRect] = [:]
    var dragHandleRects: [Int: NSRect] = [:]
    private var audioTracksOnKeyframe: Set<String> = []
    private var audioKeyframeStateFrame: Int?
    private var audioKeyframeStateRevision: Int?
    private let agentTrackLayer = CAShapeLayer()
    private var displayedAgentTrackRevision = -1
    private var labelRects: [String: (hit: NSRect, edit: NSRect)] = [:]
    private var nameEditor: NSHostingView<InlineRenameField>?
    private var editingTrackId: String?
    private var nameEditGeneration = 0
    private var pendingRenameTrackId: String?
    private struct LaneHeaderKey: Hashable {
        let trackId: String
        let property: AnimatableProperty
    }
    private var laneHeaderViews: [
        LaneHeaderKey: TimelineLaneHeaderHostingView
    ] = [:]
    private let rulerCoverView = TimelineHeaderRulerCoverView()
    private var geometry: TimelineGeometry {
        TimelineGeometry(editor: editor, bounds: bounds, laneState: keyframeLaneState)
    }

    init(editor: EditorViewModel, keyframeLaneState: TimelineKeyframeLaneState) {
        self.editor = editor
        self.keyframeLaneState = keyframeLaneState
        super.init(frame: .zero)
        wantsLayer = true
        configureAgentTrackLayer()
        updateAppearanceColors()
        addSubview(rulerCoverView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            pendingRenameTrackId = nil
            finishNameEditing()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
        rulerCoverView.needsDisplay = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        syncLaneHeaderViews(geometry: geometry)
        layoutRulerCoverView()
        updateNameEditorFrame()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background
        ctx.setFillColor(Self.headerBg)
        ctx.fill(bounds)

        // Clip drawing below the ruler so headers don't overlap it when scrolled
        let clipTop = bounds.origin.y + Layout.rulerHeight
        let visibleHeaderRect = NSRect(x: bounds.minX, y: clipTop, width: bounds.width, height: max(0, bounds.maxY - clipTop))
        ctx.clip(to: visibleHeaderRect)

        muteButtonRects.removeAll()
        hideButtonRects.removeAll()
        syncLockButtonRects.removeAll()
        keyframeButtonRects.removeAll()
        dragHandleRects.removeAll()
        labelRects.removeAll()
        let stripWidth = AppTheme.ComponentSize.timelineTrackHeaderColorStripWidth
        let iconSize: CGFloat = 14
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let headerWidth = bounds.width

        let geo = geometry

        for (i, track) in editor.timeline.tracks.enumerated() {
            let y = geo.trackY(at: i)
            let h = geo.trackHeight(at: i)

            // Lift the row being dragged
            if reorderDrag?.id == track.id {
                ctx.setFillColor(AppTheme.Background.prominent.cgColor)
                ctx.fill(NSRect(x: 0, y: y, width: headerWidth, height: h))
            }

            // Color-coded left border strip
            ctx.setFillColor(track.type.themeColor.cgColor)
            ctx.fill(NSRect(x: 0, y: y, width: stripWidth, height: h))

            // Drag handle (reorder grip)
            let gripX = AppTheme.ComponentSize.timelineTrackHeaderReorderLeadingInset
            let gripRect = NSRect(x: gripX, y: y + (h - iconSize) / 2, width: iconSize, height: iconSize)
            drawSymbol(
                "line.3.horizontal",
                in: gripRect,
                tint: AppTheme.Text.secondary.withAlphaComponent(0.4),
                config: iconConfig
            )
            dragHandleRects[i] = gripRect.insetBy(dx: -4, dy: -4)

            let iconY = y + (h - iconSize) / 2
            let rightmostX = headerWidth - iconSize - AppTheme.Spacing.sm
            let syncX = rightmostX - iconSize - AppTheme.Spacing.xs
            let keyframeX = syncX - iconSize - AppTheme.Spacing.xs

            let labelX = gripX + iconSize + AppTheme.Spacing.sm
            let labelHeight = min(
                max(0, h - AppTheme.Spacing.xs * 2),
                AppTheme.EditorPanel.fieldMinHeight
            )
            let labelRect = NSRect(
                x: labelX,
                y: y + (h - labelHeight) / 2,
                width: max(0, keyframeX - AppTheme.Spacing.xs - labelX),
                height: labelHeight
            )
            let editRect = drawTrackLabel(
                at: i,
                track: track,
                in: labelRect,
                context: ctx,
                drawsName: editingTrackId != track.id
            )
            let visibleLabelRect = labelRect.intersection(visibleHeaderRect)
            if visibleLabelRect.height >= AppTheme.FontSize.sm + AppTheme.Spacing.xs * 2 {
                labelRects[track.id] = (
                    visibleLabelRect,
                    editRect.intersection(visibleHeaderRect)
                )
            }

            syncLockButtonRects[i] = drawToggleIcon(
                x: syncX, y: iconY, size: iconSize, config: iconConfig,
                active: track.syncLocked, onSymbol: "link", offSymbol: "personalhotspot.slash"
            )
            if track.type == .audio,
               track.clips.contains(where: { $0.supportsKeyframes(for: .volume) }) {
                keyframeButtonRects[i] = drawToggleIcon(
                    x: keyframeX, y: iconY, size: iconSize, config: iconConfig,
                    active: audioTracksOnKeyframe.contains(track.id),
                    onSymbol: "diamond.fill", offSymbol: "diamond",
                    activeTint: AppTheme.Accent.timecodeNSColor
                )
            } else if !AnimatableProperty.lanes(for: track).isEmpty {
                let expanded = keyframeLaneState.isExpanded(trackId: track.id)
                keyframeButtonRects[i] = drawToggleIcon(
                    x: keyframeX, y: iconY, size: iconSize, config: iconConfig,
                    active: expanded, onSymbol: "diamond.fill", offSymbol: "diamond",
                    activeTint: AppTheme.Accent.timecodeNSColor
                )
            }
            if track.type == .audio {
                muteButtonRects[i] = drawToggleIcon(
                    x: rightmostX, y: iconY, size: iconSize, config: iconConfig,
                    active: !track.muted, onSymbol: "speaker.wave.2.fill", offSymbol: "speaker.slash.fill"
                )
            } else {
                hideButtonRects[i] = drawToggleIcon(
                    x: rightmostX, y: iconY, size: iconSize, config: iconConfig,
                    active: !track.hidden, onSymbol: "eye", offSymbol: "eye.slash"
                )
            }

            if i == 0 {
                ctx.setFillColor(AppTheme.Border.primary.cgColor)
                ctx.fill(NSRect(x: 0, y: y, width: headerWidth, height: 1))
            }

            // Bottom edge is the resize handle for each track.
            let handleY = y + h - 1
            ctx.setFillColor(AppTheme.Border.primary.cgColor)
            ctx.fill(NSRect(x: 0, y: handleY, width: headerWidth, height: 1))
            if !geo.laneProperties[i].isEmpty {
                let blockBottom = geo.trackBlockBottom(at: i) - AppTheme.BorderWidth.thin
                ctx.fill(NSRect(
                    x: 0,
                    y: blockBottom,
                    width: headerWidth,
                    height: AppTheme.BorderWidth.thin
                ))
            }
        }
        syncAgentTrackLayer(geometry: geo, headerWidth: headerWidth)

        // Thick divider between the video zone and the audio zone,
        let z = editor.zones
        if z.videoTrackCount > 0, z.audioTrackCount > 0 {
            let dividerY = geo.trackY(at: z.firstAudioIndex)
            ctx.setFillColor(AppTheme.Border.divider.withAlphaComponent(AppTheme.Opacity.medium).cgColor)
            ctx.fill(NSRect(x: 0, y: dividerY - 1, width: headerWidth, height: 2))
        }
    }

    func updateAgentActivityOverlay() {
        syncAgentTrackLayer(geometry: geometry, headerWidth: bounds.width)
    }

    private func configureAgentTrackLayer() {
        agentTrackLayer.fillColor = nil
        agentTrackLayer.lineWidth = AppTheme.BorderWidth.thick
        agentTrackLayer.shadowOpacity = AppTheme.AgentActivity.changeGlowOpacity
        agentTrackLayer.shadowRadius = AppTheme.AgentActivity.changeGlowRadius
        agentTrackLayer.shadowOffset = .zero
        agentTrackLayer.zPosition = 90
        agentTrackLayer.opacity = 0
        layer?.addSublayer(agentTrackLayer)
    }

    private func updateAgentTrackColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = AppTheme.AgentActivity.mutated.cgColor
            agentTrackLayer.strokeColor = color
            agentTrackLayer.shadowColor = color
        }
    }

    private func syncAgentTrackLayer(geometry: TimelineGeometry, headerWidth: CGFloat) {
        let activity = editor.agentActivity
        guard !activity.mutatedTrackIds.isEmpty
                || activity.revision != displayedAgentTrackRevision else { return }
        let path = CGMutablePath()
        for (index, track) in editor.timeline.tracks.enumerated()
            where activity.mutatedTrackIds.contains(track.id) {
            let rect = NSRect(
                x: 0,
                y: geometry.trackY(at: index),
                width: headerWidth,
                height: geometry.trackHeight(at: index)
            )
            guard rect.intersects(bounds) else { continue }
            let ringRect = rect
                .offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                .insetBy(
                    dx: AppTheme.BorderWidth.hairline,
                    dy: AppTheme.BorderWidth.hairline
                )
            path.addRoundedRect(
                in: ringRect,
                cornerWidth: AppTheme.Radius.xs,
                cornerHeight: AppTheme.Radius.xs
            )
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        agentTrackLayer.frame = bounds
        agentTrackLayer.path = path.isEmpty ? nil : path
        AgentActivityLayerSupport.updateMask(
            agentTrackLayer,
            bounds: agentTrackLayer.bounds,
            rulerHeight: Layout.rulerHeight
        )
        CATransaction.commit()

        guard activity.revision != displayedAgentTrackRevision else { return }
        displayedAgentTrackRevision = activity.revision
        AgentActivityLayerSupport.updateAnimation(
            agentTrackLayer,
            hasHighlight: !activity.mutatedTrackIds.isEmpty,
            staysVisible: false,
            hold: AppTheme.Anim.agentChangeHighlightHold,
            duration: AppTheme.Anim.agentChangeHighlightDuration
        )
    }

    private func drawTrackLabel(
        at trackIndex: Int,
        track: Track,
        in rect: NSRect,
        context: CGContext,
        drawsName: Bool
    ) -> NSRect {
        let designation = NSAttributedString(
            string: editor.timelineTrackDisplayLabel(at: trackIndex),
            attributes: labelAttrs
        )
        let designationSize = designation.size()
        let designationRect = NSRect(
            x: rect.minX,
            y: rect.midY - designationSize.height / 2,
            width: min(rect.width, designationSize.width),
            height: designationSize.height
        )
        designation.draw(in: designationRect)

        let nameRect = NSRect(
            x: designationRect.maxX + AppTheme.Spacing.xs,
            y: rect.minY,
            width: max(0, rect.maxX - designationRect.maxX - AppTheme.Spacing.xs),
            height: rect.height
        )
        if drawsName, let name = track.name {
            let pillHeight = AppTheme.FontSize.sm + AppTheme.ComponentSize.timelineBadgePadV * 2
            ClipRenderer.drawPill(
                name,
                textColor: track.type.themeForegroundColor,
                fill: track.type.themeColor.withAlphaComponent(AppTheme.Opacity.prominent),
                fontSize: AppTheme.FontSize.sm,
                at: NSPoint(x: nameRect.minX, y: nameRect.midY - pillHeight / 2),
                maxWidth: nameRect.width,
                context: context
            )
        }
        return nameRect
    }

    private func syncLaneHeaderViews(geometry: TimelineGeometry) {
        var desired: Set<LaneHeaderKey> = []
        let visibleRows = NSRect(
            x: bounds.minX,
            y: bounds.minY + Layout.rulerHeight,
            width: bounds.width,
            height: max(0, bounds.height - Layout.rulerHeight)
        )
        for (trackIndex, track) in editor.timeline.tracks.enumerated() {
            let properties = geometry.laneProperties[trackIndex]
            for (laneIndex, property) in properties.enumerated() {
                let key = LaneHeaderKey(trackId: track.id, property: property)
                desired.insert(key)
                if laneHeaderViews[key] == nil {
                    let host = TimelineLaneHeaderHostingView(rootView: TimelineKeyframeLaneHeaderControl(
                        editor: editor,
                        trackId: track.id,
                        property: property
                    ))
                    host.setAccessibilityLabel(L10n.string("Keyframes"))
                    laneHeaderViews[key] = host
                    addSubview(host, positioned: .below, relativeTo: rulerCoverView)
                }
                guard let host = laneHeaderViews[key],
                      let laneY = geometry.laneY(trackIndex: trackIndex, property: property) else {
                    continue
                }
                host.frame = NSRect(
                    x: bounds.minX,
                    y: laneY,
                    width: bounds.width,
                    height: AppTheme.ComponentSize.timelineKeyframeLaneHeight
                )
                host.bottomPassthroughHeight = laneIndex == properties.count - 1
                    ? TrackSize.resizeHandleZone
                    : 0
                host.leadingPassthroughWidth =
                    AppTheme.ComponentSize.timelineKeyframeResizeHandleWidth
                host.isHidden = !host.frame.intersects(visibleRows)
            }
        }
        for key in laneHeaderViews.keys.filter({ !desired.contains($0) }) {
            laneHeaderViews.removeValue(forKey: key)?.removeFromSuperview()
        }
    }

    private func layoutRulerCoverView() {
        rulerCoverView.frame = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: Layout.rulerHeight
        )
    }

    /// Draw a toggleable SF Symbol button; returns the hit-test rect (padded).
    private func drawToggleIcon(
        x: CGFloat, y: CGFloat, size: CGFloat,
        config: NSImage.SymbolConfiguration,
        active: Bool, onSymbol: String, offSymbol: String,
        activeTint: NSColor = AppTheme.Text.secondary
    ) -> NSRect {
        let rect = NSRect(x: x, y: y, width: size, height: size)
        let tint = active
            ? activeTint
            : AppTheme.Text.secondary.withAlphaComponent(0.3)
        drawSymbol(active ? onSymbol : offSymbol, in: rect, tint: tint, config: config)
        return rect.insetBy(dx: -4, dy: -4)
    }

    private func drawSymbol(
        _ name: String,
        in rect: NSRect,
        tint: NSColor,
        config: NSImage.SymbolConfiguration
    ) {
        guard let img = TimelineHeaderSymbol.image(named: name, tint: tint, configuration: config) else { return }
        let symbolSize = img.size
        let drawRect = NSRect(x: rect.midX - symbolSize.width / 2, y: rect.midY - symbolSize.height / 2, width: symbolSize.width, height: symbolSize.height)
        img.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    private func updateAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Self.headerBg
            labelAttrs = [
                .font: Self.labelFont,
                .foregroundColor: AppTheme.Text.secondary.usingColorSpace(.sRGB) ?? AppTheme.Text.secondary,
            ]
        }
        updateAgentTrackColor()
    }

    // MARK: - Track names

    private func beginNameEditing(trackId: String) {
        guard let trackIndex = editor.timeline.tracks.firstIndex(where: { $0.id == trackId }),
              let frame = labelRects[trackId]?.edit else { return }
        if nameEditor != nil {
            pendingRenameTrackId = trackId
            window?.makeFirstResponder(nil)
            return
        }
        let generation = nameEditGeneration
        let timelineId = editor.activeTimelineId
        let field = InlineRenameField(
            originalName: editor.timeline.tracks[trackIndex].name ?? "",
            placeholder: editor.timelineTrackDisplayLabel(at: trackIndex),
            font: .system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium),
            maximumLength: TrackName.maximumLength,
            allowsEmptyCommit: true,
            onCommit: { [weak self] name in
                self?.commitNameEditing(name, trackId: trackId, timelineId: timelineId, generation: generation)
            },
            onCancel: { [weak self] in self?.finishNameEditing(generation: generation) }
        )
        let host = NSHostingView(rootView: field)
        host.frame = frame
        host.setAccessibilityLabel(L10n.string("Track Name"))
        nameEditor = host
        editingTrackId = trackId
        addSubview(host, positioned: .below, relativeTo: rulerCoverView)
        needsDisplay = true
    }

    private func commitNameEditing(_ name: String, trackId: String, timelineId: String, generation: Int) {
        guard generation == nameEditGeneration else { return }
        defer { finishNameEditing(generation: generation) }
        guard editor.activeTimelineId == timelineId else { return }
        do { _ = try editor.setTrackName(id: trackId, to: name) }
        catch { NSSound.beep() }
    }

    private func finishNameEditing(generation: Int? = nil) {
        guard generation == nil || generation == nameEditGeneration else { return }
        let pendingTrackId = pendingRenameTrackId
        pendingRenameTrackId = nil
        nameEditGeneration &+= 1
        nameEditor?.removeFromSuperview()
        nameEditor = nil
        editingTrackId = nil
        needsDisplay = true
        if let pendingTrackId {
            DispatchQueue.main.async { [weak self] in self?.beginNameEditing(trackId: pendingTrackId) }
        }
    }

    private func updateNameEditorFrame() {
        guard let field = nameEditor, let trackId = editingTrackId else { return }
        guard editor.timeline.tracks.contains(where: { $0.id == trackId }) else {
            DispatchQueue.main.async { [weak self] in
                guard self?.editingTrackId == trackId else { return }
                self?.finishNameEditing()
            }
            return
        }
        guard let frame = labelRects[trackId]?.edit else {
            field.isHidden = true
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field, self.nameEditor === field else { return }
                self.window?.makeFirstResponder(nil)
            }
            return
        }
        field.isHidden = false
        if field.frame != frame { field.frame = frame }
    }

    // MARK: - Input handling

    private var resizeDrag: (trackIndex: Int, originalHeight: CGFloat)?
    private var reorderDrag: (id: String, before: Timeline)?

    private func hitTestTrack(at point: NSPoint) -> Int? {
        let geo = geometry
        return editor.timeline.tracks.indices.first { index in
            NSRect(
                x: bounds.minX,
                y: geo.trackY(at: index),
                width: bounds.width,
                height: geo.trackHeight(at: index)
            ).contains(point)
        }
    }

    private func hitTestResizeHandle(at point: NSPoint) -> Int? {
        let geo = geometry
        for i in editor.timeline.tracks.indices {
            let trackBottom = geo.trackBlockBottom(at: i)
            if abs(point.y - trackBottom) <= TrackSize.resizeHandleZone {
                return i
            }
        }
        return nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let trackIndex = hitTestTrack(at: point) else { return nil }
        let track = editor.timeline.tracks[trackIndex]
        let menu = NSMenu()
        menu.autoenablesItems = false
        let renameItem = NSMenuItem(
            title: L10n.string("Rename Track"),
            action: #selector(performRenameTrack(_:)),
            keyEquivalent: ""
        )
        renameItem.target = self
        renameItem.representedObject = track.id
        renameItem.isEnabled = labelRects[track.id] != nil
        menu.addItem(renameItem)
        menu.addItem(.separator())
        let item = NSMenuItem(
            title: L10n.string("Select All Clips on Track"),
            action: #selector(performSelectAllClipsOnTrack(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = track.id
        item.isEnabled = !track.clips.isEmpty
        menu.addItem(item)
        return menu
    }

    @objc private func performRenameTrack(_ sender: NSMenuItem) {
        guard let trackId = sender.representedObject as? String else { return }
        beginNameEditing(trackId: trackId)
    }

    @objc private func performSelectAllClipsOnTrack(_ sender: NSMenuItem) {
        guard let trackId = sender.representedObject as? String,
              editor.selectAllClips(onTrack: trackId) else { return }
        needsDisplay = true
        requestCanvasRedraw?()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if nameEditor != nil, nameEditor?.frame.contains(point) != true {
            window?.makeFirstResponder(nil)
        }

        if event.clickCount == 2,
           let trackId = labelRects.first(where: { $0.value.hit.contains(point) })?.key {
            beginNameEditing(trackId: trackId)
            return
        }

        for (ti, rect) in muteButtonRects {
            if rect.contains(point) {
                editor.toggleTrackMute(trackIndex: ti)
                needsDisplay = true
                return
            }
        }
        for (ti, rect) in hideButtonRects {
            if rect.contains(point) {
                editor.toggleTrackHidden(trackIndex: ti)
                needsDisplay = true
                return
            }
        }
        for (ti, rect) in syncLockButtonRects {
            if rect.contains(point) {
                editor.toggleTrackSyncLock(trackIndex: ti)
                needsDisplay = true
                return
            }
        }
        for (ti, rect) in keyframeButtonRects {
            if rect.contains(point), editor.timeline.tracks.indices.contains(ti) {
                let track = editor.timeline.tracks[ti]
                if track.type == .audio {
                    toggleVolumeKeyframe(on: track)
                } else {
                    keyframeLaneState.toggle(trackId: track.id)
                }
                return
            }
        }

        for (ti, rect) in dragHandleRects {
            if rect.contains(point) {
                reorderDrag = (editor.timeline.tracks[ti].id, editor.timeline)
                NSCursor.closedHand.set()
                return
            }
        }

        if let ti = hitTestResizeHandle(at: point) {
            resizeDrag = (ti, editor.timeline.tracks[ti].displayHeight)
        }
    }

    func updateAudioKeyframeButtonStates(at frame: Int, revision: Int) {
        guard audioKeyframeStateFrame != frame
            || audioKeyframeStateRevision != revision else { return }
        audioKeyframeStateFrame = frame
        audioKeyframeStateRevision = revision

        let next = Set(editor.timeline.tracks.compactMap { track -> String? in
            guard track.type == .audio,
                  let clip = editor.keyframeLaneTarget(
                      trackId: track.id,
                      property: .volume,
                      at: frame
                  ),
                  editor.hasKeyframe(
                      clipId: clip.id,
                      property: .volume,
                      at: frame
                  ) else {
                return nil
            }
            return track.id
        })
        guard next != audioTracksOnKeyframe else { return }
        audioTracksOnKeyframe = next
        needsDisplay = true
    }

    private func toggleVolumeKeyframe(on track: Track) {
        let frame = editor.activeFrame
        guard let clip = editor.keyframeLaneTarget(
            trackId: track.id,
            property: .volume,
            at: frame
        ) else { return }
        editor.selectedGap = nil
        editor.selectedClipIds = [clip.id]
        editor.toggleKeyframe(clipId: clip.id, property: .volume, at: frame)
        updateAudioKeyframeButtonStates(
            at: frame,
            revision: editor.timelineRenderRevision
        )
        requestCanvasRedraw?()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let drag = reorderDrag {
            let geo = geometry
            editor.reorderTrackLive(id: drag.id, to: geo.trackAt(y: Double(point.y)))
            NSCursor.closedHand.set()
            needsLayout = true
            needsDisplay = true
            requestCanvasRedraw?()
            return
        }

        guard let drag = resizeDrag else { return }
        let geo = geometry
        let trackTop = geo.trackY(at: drag.trackIndex)
        let lanesHeight = CGFloat(geo.laneProperties[drag.trackIndex].count)
            * AppTheme.ComponentSize.timelineKeyframeLaneHeight
        let newHeight = max(
            TrackSize.minHeight,
            min(TrackSize.maxHeight, point.y - trackTop - lanesHeight)
        )
        if editor.timeline.tracks[drag.trackIndex].displayHeight != newHeight {
            editor.timeline.tracks[drag.trackIndex].displayHeight = newHeight
            needsLayout = true
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let drag = reorderDrag {
            reorderDrag = nil
            editor.commitTrackReorder(before: drag.before)
            needsDisplay = true
            return
        }

        guard let drag = resizeDrag else { return }
        let finalHeight = editor.timeline.tracks[drag.trackIndex].displayHeight
        if finalHeight != drag.originalHeight {
            editor.timeline.tracks[drag.trackIndex].displayHeight = drag.originalHeight
            editor.setTrackHeight(trackIndex: drag.trackIndex, height: finalHeight)
        }
        resizeDrag = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let trackIndex = keyframeButtonRects.first(where: {
            $0.value.contains(point)
        })?.key,
           editor.timeline.tracks.indices.contains(trackIndex) {
            let track = editor.timeline.tracks[trackIndex]
            if track.type == .audio {
                let target = editor.keyframeLaneTarget(
                    trackId: track.id,
                    property: .volume
                )
                if let target {
                    let onKeyframe = editor.hasKeyframe(
                        clipId: target.id,
                        property: .volume,
                        at: editor.activeFrame
                    )
                    updateToolTip(onKeyframe
                        ? L10n.string("Delete keyframe")
                        : L10n.string("Add keyframe"))
                    NSCursor.pointingHand.set()
                } else {
                    updateToolTip(L10n.string("Move playhead inside the clip"))
                    NSCursor.arrow.set()
                }
            } else {
                updateToolTip(keyframeLaneState.isExpanded(trackId: track.id)
                    ? L10n.string("Hide clip keyframes")
                    : L10n.string("Show clip keyframes"))
                NSCursor.pointingHand.set()
            }
        } else if dragHandleRects.values.contains(where: { $0.contains(point) }) {
            updateToolTip(nil)
            NSCursor.openHand.set()
        } else if hitTestResizeHandle(at: point) != nil {
            updateToolTip(nil)
            NSCursor.resizeUpDown.set()
        } else {
            updateToolTip(nil)
            NSCursor.arrow.set()
        }
    }

    private func updateToolTip(_ value: String?) {
        guard toolTip != value else { return }
        toolTip = value
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
}

private final class TimelineLaneHeaderHostingView:
    NSHostingView<TimelineKeyframeLaneHeaderControl>
{
    var bottomPassthroughHeight: CGFloat = 0
    var leadingPassthroughWidth: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        if bottomPassthroughHeight > 0,
           point.x <= frame.minX + leadingPassthroughWidth,
           point.y >= frame.maxY - bottomPassthroughHeight {
            return nil
        }
        return super.hitTest(point)
    }
}

private final class TimelineHeaderRulerCoverView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        AppTheme.Background.surface.setFill()
        bounds.fill()
    }
}
