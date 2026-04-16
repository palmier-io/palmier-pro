import SwiftUI

struct TimelineContainerView: NSViewRepresentable {
    @Environment(EditorViewModel.self) var editor

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        // Fixed header on the left
        let headerView = TimelineHeaderView(editor: editor)
        headerView.frame = NSRect(x: 0, y: 0, width: Layout.trackHeaderWidth, height: 0)
        headerView.autoresizingMask = [.height]
        container.addSubview(headerView)

        // Scroll view for clips/ruler on the right
        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.horizontalScroller?.controlSize = .mini

        let timelineView = TimelineView(editor: editor)
        timelineView.autoresizingMask = [.height]
        scrollView.documentView = timelineView

        scrollView.frame = NSRect(x: Layout.trackHeaderWidth, y: 0, width: 0, height: 0)
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)

        context.coordinator.headerView = headerView
        context.coordinator.timelineView = timelineView
        context.coordinator.scrollView = scrollView

        // Redraw ruler when scroll position changes; resize content when clip view frame changes
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

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Read zoomScale so SwiftUI re-invokes this when zoom changes
        _ = editor.zoomScale
        let coordinator = context.coordinator
        DispatchQueue.main.async { coordinator.timelineView?.updateContentSize() }
        context.coordinator.timelineView?.needsDisplay = true
        context.coordinator.headerView?.needsDisplay = true

        // Auto-scroll to keep playhead visible during playback
        if editor.isPlaying,
           let timelineView = context.coordinator.timelineView,
           let scrollView = context.coordinator.scrollView {
            let geo = timelineView.geometry
            let playheadX = geo.xForFrame(editor.currentFrame)
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

    final class Coordinator: NSObject {
        var headerView: TimelineHeaderView?
        var timelineView: TimelineView?
        var scrollView: NSScrollView?

        @MainActor @objc func scrollViewBoundsChanged(_ notification: Notification) {
            timelineView?.needsDisplay = true
            // Sync header vertical position with scroll view
            if let scrollY = scrollView?.contentView.bounds.origin.y {
                headerView?.setBoundsOrigin(NSPoint(x: 0, y: scrollY))
                headerView?.needsDisplay = true
            }
        }

        @MainActor @objc func clipViewFrameChanged(_ notification: Notification) {
            timelineView?.updateContentSize()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
