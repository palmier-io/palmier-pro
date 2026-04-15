import AppKit

/// Fixed track header column drawn to the left of the scrollable timeline.
final class TimelineHeaderView: NSView {
    unowned var editor: EditorViewModel

    private static let headerBg = AppTheme.Background.timelineHeader.cgColor
    private static let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: AppTheme.FontSize.sm, weight: .medium),
        .foregroundColor: AppTheme.Text.secondary,
    ]

    /// Rects for mute/hide buttons, indexed by track. Used for hit testing.
    var muteButtonRects: [Int: NSRect] = [:]
    var hideButtonRects: [Int: NSRect] = [:]

    init(editor: EditorViewModel) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.headerBg
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background
        ctx.setFillColor(Self.headerBg)
        ctx.fill(bounds)

        // Clip drawing below the ruler so headers don't overlap it when scrolled
        let clipTop = bounds.origin.y + Layout.rulerHeight
        ctx.clip(to: NSRect(x: bounds.origin.x, y: clipTop, width: bounds.width, height: bounds.height))

        muteButtonRects.removeAll()
        hideButtonRects.removeAll()
        let stripWidth: CGFloat = 3
        let iconSize: CGFloat = 14
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let headerWidth = bounds.width

        let geo = TimelineGeometry(editor: editor, bounds: bounds)

        for (i, track) in editor.timeline.tracks.enumerated() {
            let y = geo.trackY(at: i)
            let h = geo.trackHeight(at: i)

            // Color-coded left border strip
            ctx.setFillColor(track.type.themeColor.cgColor)
            ctx.fill(NSRect(x: 0, y: y, width: stripWidth, height: h))

            // Track label
            let str = NSAttributedString(string: track.label, attributes: Self.labelAttrs)
            let labelSize = str.size()
            let labelY = y + (h - labelSize.height) / 2
            str.draw(at: NSPoint(x: stripWidth + 6, y: labelY))

            // Mute + hide buttons
            let iconY = y + (h - iconSize) / 2
            let hideX = headerWidth - iconSize - 6
            let muteX = hideX - iconSize - 4

            let muteIcon = track.muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
            let muteTint: NSColor = track.muted ? AppTheme.Text.secondary.withAlphaComponent(0.3) : AppTheme.Text.secondary
            let muteRect = NSRect(x: muteX, y: iconY, width: iconSize, height: iconSize)
            drawSymbol(muteIcon, in: muteRect, tint: muteTint, config: iconConfig, context: ctx)
            muteButtonRects[i] = muteRect.insetBy(dx: -4, dy: -4)

            let hideIcon = track.hidden ? "eye.slash" : "eye"
            let hideTint: NSColor = track.hidden ? AppTheme.Text.secondary.withAlphaComponent(0.3) : AppTheme.Text.secondary
            let hideRect = NSRect(x: hideX, y: iconY, width: iconSize, height: iconSize)
            drawSymbol(hideIcon, in: hideRect, tint: hideTint, config: iconConfig, context: ctx)
            hideButtonRects[i] = hideRect.insetBy(dx: -4, dy: -4)

            // Resize handle at bottom
            let handleY = y + h - 1
            ctx.setFillColor(AppTheme.Border.subtle.cgColor)
            ctx.fill(NSRect(x: 0, y: handleY, width: headerWidth, height: 1))
        }
    }

    private func drawSymbol(_ name: String, in rect: NSRect, tint: NSColor, config: NSImage.SymbolConfiguration, context: CGContext) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let symbolSize = img.size
        let drawRect = NSRect(x: rect.midX - symbolSize.width / 2, y: rect.midY - symbolSize.height / 2, width: symbolSize.width, height: symbolSize.height)
        let tinted = NSImage(size: drawRect.size, flipped: true) { drawRect in
            tint.set()
            img.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            drawRect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    // MARK: - Input handling (mute/hide/resize)

    private var resizeDrag: (trackIndex: Int, originalHeight: CGFloat)?

    private func hitTestResizeHandle(at point: NSPoint) -> Int? {
        let geo = TimelineGeometry(editor: editor, bounds: bounds)
        for i in editor.timeline.tracks.indices {
            let trackBottom = geo.trackY(at: i) + geo.trackHeight(at: i)
            if abs(point.y - trackBottom) <= TrackSize.resizeHandleZone {
                return i
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

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

        if let ti = hitTestResizeHandle(at: point) {
            resizeDrag = (ti, editor.timeline.tracks[ti].displayHeight)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag = resizeDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let geo = TimelineGeometry(editor: editor, bounds: bounds)
        let trackTop = geo.trackY(at: drag.trackIndex)
        let newHeight = max(TrackSize.minHeight, min(TrackSize.maxHeight, point.y - trackTop))
        editor.timeline.tracks[drag.trackIndex].displayHeight = newHeight
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
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
        if hitTestResizeHandle(at: point) != nil {
            NSCursor.resizeUpDown.set()
        } else {
            NSCursor.arrow.set()
        }
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
