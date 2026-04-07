import SwiftUI

struct TimelineContainerView: NSViewRepresentable {
    @Environment(EditorViewModel.self) var editor

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let timelineView = TimelineView(editor: editor)
        timelineView.autoresizingMask = [.width, .height]
        scrollView.documentView = timelineView

        context.coordinator.timelineView = timelineView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.timelineView?.needsDisplay = true

        // Auto-scroll to keep playhead visible during playback
        if editor.isPlaying, let timelineView = context.coordinator.timelineView {
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

    final class Coordinator {
        var timelineView: TimelineView?
        var scrollView: NSScrollView?
    }
}
