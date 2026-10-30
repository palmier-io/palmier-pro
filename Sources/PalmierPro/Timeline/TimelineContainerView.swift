import SwiftUI

extension NSView {
    func ownsTimelinePointer(at windowPoint: NSPoint) -> Bool {
        guard let contentView = window?.contentView else { return false }
        var hitView = contentView.hitTest(windowPoint)
        while let current = hitView {
            if current === self { return true }
            hitView = current.superview
        }
        return false
    }
}

struct TimelineContainerView: NSViewRepresentable {
    @Environment(EditorViewModel.self) var editor

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let headerWidth = Layout.trackHeaderDefaultWidth
        let keyframeLaneState = TimelineKeyframeLaneState()

        let headerView = TimelineHeaderView(editor: editor, keyframeLaneState: keyframeLaneState)
        headerView.updateAudioKeyframeButtonStates(
            at: editor.activeFrame,
            revision: editor.timelineRenderRevision
        )
        headerView.frame = NSRect(x: 0, y: 0, width: headerWidth, height: 0)
        headerView.autoresizingMask = [.height]
        container.addSubview(headerView)

        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.horizontalScroller?.controlSize = .mini
        scrollView.verticalScroller?.controlSize = .mini

        let timelineView = TimelineView(editor: editor, keyframeLaneState: keyframeLaneState)
        timelineView.autoresizingMask = []
        scrollView.documentView = timelineView
        headerView.requestCanvasRedraw = { [weak timelineView] in timelineView?.needsDisplay = true }

        scrollView.frame = NSRect(x: headerWidth, y: 0, width: 0, height: 0)
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)

        let resizeHandle = TimelineHeaderResizeHandleView(
            headerView: headerView,
            scrollView: scrollView,
            timelineView: timelineView,
            keyframeLaneState: keyframeLaneState,
            headerWidth: headerWidth
        )
        resizeHandle.frame = NSRect(
            x: headerWidth,
            y: 0,
            width: Layout.trackHeaderResizeHitWidth,
            height: 0
        )
        resizeHandle.autoresizingMask = [.height]
        container.addSubview(resizeHandle)

        context.coordinator.headerView = headerView
        context.coordinator.timelineView = timelineView
        context.coordinator.scrollView = scrollView
        context.coordinator.editor = editor
        context.coordinator.keyframeLaneState = keyframeLaneState
        keyframeLaneState.onChange = {
            [weak headerView, weak timelineView, weak resizeHandle, weak keyframeLaneState] in
            if keyframeLaneState?.expandedTrackIds.isEmpty == false {
                resizeHandle?.ensureMinimumWidth(
                    AppTheme.ComponentSize.timelineKeyframeTrackHeaderMinimumWidth
                )
            }
            timelineView?.inputController.cancelActiveDrag()
            timelineView?.updateContentSize()
            timelineView?.needsDisplay = true
            headerView?.needsLayout = true
            headerView?.needsDisplay = true
        }

        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewFrameChanged),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.timelineClipColorsDidChange),
            name: .timelineClipColorsDidChange,
            object: nil
        )
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.headerView?.updateAudioKeyframeButtonStates(
            at: editor.activeFrame,
            revision: editor.timelineRenderRevision
        )
        context.coordinator.keyframeLaneState?.update(
            timelineId: editor.activeTimelineId,
            revision: editor.timelineRenderRevision,
            tracks: editor.timeline.tracks
        )
        let renderState = RenderState(
            revision: editor.timelineRenderRevision,
            zoomScale: editor.zoomScale,
            keyframeLaneRevision: context.coordinator.keyframeLaneState?.revision ?? 0,
            selectedClipIds: editor.selectedClipIds,
            selectedTimelineRange: editor.selectedTimelineRange,
            selectedTimelineMarkerIds: editor.selectedTimelineMarkerIds,
            timelineMarkerPreview: editor.timelineMarkerPreview,
            pendingReplacements: editor.pendingReplacements,
            generatingAssetIds: Set(editor.mediaAssets.lazy.filter(\.isGenerating).map(\.id))
        )

        let changes = context.coordinator.renderChanges(for: renderState)
        if changes.needsRender {
            context.coordinator.timelineView?.updateContentSize()
            context.coordinator.timelineView?.needsDisplay = true
            context.coordinator.headerView?.needsDisplay = true
        }
        if changes.needsHeaderStructure {
            context.coordinator.headerView?.needsLayout = true
        }
        context.coordinator.updateAgentActivity(editor.agentActivity)

        if let x = editor.timelineScrollRestoreX,
           let scrollView = context.coordinator.scrollView {
            let y = scrollView.contentView.bounds.origin.y
            scrollView.contentView.setBoundsOrigin(NSPoint(x: max(0, x), y: y))
            DispatchQueue.main.async { editor.timelineScrollRestoreX = nil }
        }

        if editor.isPlaying,
           let timelineView = context.coordinator.timelineView,
           let scrollView = context.coordinator.scrollView {
            let geo = timelineView.geometry
            let playheadX = geo.xForFrame(editor.activeFrame)
            let visibleRect = scrollView.contentView.bounds
            let margin: CGFloat = 60

            if playheadX < visibleRect.origin.x + margin ||
               playheadX > visibleRect.origin.x + visibleRect.width - margin {
                let newOriginX = max(0, playheadX - visibleRect.width * 0.25)
                scrollView.contentView.setBoundsOrigin(
                    NSPoint(x: newOriginX, y: visibleRect.origin.y)
                )
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    struct RenderState: Equatable {
        let revision: Int
        let zoomScale: Double
        let keyframeLaneRevision: Int
        let selectedClipIds: Set<String>
        let selectedTimelineRange: TimelineRangeSelection?
        let selectedTimelineMarkerIds: Set<String>
        let timelineMarkerPreview: TimelineMarker?
        let pendingReplacements: Set<String>
        let generatingAssetIds: Set<String>
    }

    final class Coordinator: NSObject {
        var headerView: TimelineHeaderView?
        var timelineView: TimelineView?
        var scrollView: NSScrollView?
        weak var editor: EditorViewModel?
        var keyframeLaneState: TimelineKeyframeLaneState?
        private var renderState: RenderState?
        private var agentActivity = AgentActivityHighlight()

        func renderChanges(
            for next: RenderState
        ) -> (needsRender: Bool, needsHeaderStructure: Bool) {
            let previous = renderState
            defer { renderState = next }
            return (
                previous != next,
                previous?.revision != next.revision
                    || previous?.keyframeLaneRevision != next.keyframeLaneRevision
            )
        }

        @MainActor func updateAgentActivity(_ next: AgentActivityHighlight) {
            guard agentActivity != next else { return }
            agentActivity = next
            timelineView?.updateAgentActivityOverlay()
            headerView?.updateAgentActivityOverlay()
        }

        @MainActor @objc func scrollViewBoundsChanged(_ notification: Notification) {
            timelineView?.needsDisplay = true
            timelineView?.updatePlayheadLayer()
            if let scrollX = scrollView?.contentView.bounds.origin.x {
                editor?.timelineScrollOffsetX = scrollX
            }
            if let scrollY = scrollView?.contentView.bounds.origin.y {
                headerView?.setBoundsOrigin(NSPoint(x: 0, y: scrollY))
                headerView?.needsLayout = true
                headerView?.needsDisplay = true
            }
        }

        @MainActor @objc func clipViewFrameChanged(_ notification: Notification) {
            timelineView?.updateContentSize()
            timelineView?.updatePlayheadLayer()
            headerView?.needsLayout = true
        }

        @MainActor @objc func timelineClipColorsDidChange(_ notification: Notification) {
            if let timelineView {
                timelineView.setNeedsDisplay(timelineView.visibleRect)
            }
            if let headerView {
                headerView.setNeedsDisplay(headerView.visibleRect)
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

private final class TimelineHeaderResizeHandleView: NSView {
    private weak var headerView: TimelineHeaderView?
    private weak var scrollView: NSScrollView?
    private weak var timelineView: TimelineView?
    private weak var keyframeLaneState: TimelineKeyframeLaneState?
    private var headerWidth: CGFloat
    private var dragStart: (x: CGFloat, width: CGFloat)?

    init(
        headerView: TimelineHeaderView,
        scrollView: NSScrollView,
        timelineView: TimelineView,
        keyframeLaneState: TimelineKeyframeLaneState,
        headerWidth: CGFloat
    ) {
        self.headerView = headerView
        self.scrollView = scrollView
        self.timelineView = timelineView
        self.keyframeLaneState = keyframeLaneState
        self.headerWidth = headerWidth
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            AppTheme.Border.primary.setFill()
            let lineWidth = AppTheme.BorderWidth.thin
            NSRect(
                x: bounds.minX,
                y: bounds.minY,
                width: lineWidth,
                height: bounds.height
            ).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let localPoint = convert(point, from: superview)
        let windowPoint = superview.convert(point, to: nil)
        guard localPoint.y >= Layout.rulerHeight,
              !clipHasPriority(at: windowPoint) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = (event.locationInWindow.x, headerWidth)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        NSCursor.resizeLeftRight.set()
        resizeHeader(to: dragStart.width + event.locationInWindow.x - dragStart.x)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
    }

    private func resizeHeader(to requestedWidth: CGFloat) {
        guard let container = superview,
              let headerView,
              let scrollView,
              let timelineView else { return }
        let minimumWidth = keyframeLaneState?.expandedTrackIds.isEmpty == false
            ? AppTheme.ComponentSize.timelineKeyframeTrackHeaderMinimumWidth
            : Layout.trackHeaderMinimumWidth
        let width = min(
            Layout.trackHeaderMaximumWidth,
            max(minimumWidth, requestedWidth)
        )
        guard width != headerWidth else { return }
        headerWidth = width
        headerView.frame.size.width = width
        scrollView.frame = NSRect(
            x: width,
            y: scrollView.frame.minY,
            width: max(0, container.bounds.width - width),
            height: scrollView.frame.height
        )
        frame.origin.x = width
        headerView.needsLayout = true
        headerView.needsDisplay = true
        timelineView.updateContentSize()
        timelineView.needsDisplay = true
    }

    func ensureMinimumWidth(_ minimumWidth: CGFloat) {
        guard headerWidth < minimumWidth else { return }
        resizeHeader(to: minimumWidth)
    }

    private func clipHasPriority(at windowPoint: NSPoint) -> Bool {
        guard let timelineView else { return false }
        let point = timelineView.convert(windowPoint, from: nil)
        let geometry = timelineView.geometry
        return timelineView.inputController.hitTestClip(
            at: point,
            trackIndex: geometry.trackAt(y: point.y),
            geometry: geometry
        ) != nil
    }

    override func mouseMoved(with event: NSEvent) {
        guard ownsTimelinePointer(at: event.locationInWindow) else { return }
        NSCursor.resizeLeftRight.set()
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
