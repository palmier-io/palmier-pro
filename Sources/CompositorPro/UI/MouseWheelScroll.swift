import SwiftUI

/// While the cursor is over the view, translate vertical mouse-wheel deltas into
/// horizontal scroll events so a plain mouse can drive an `.horizontal` ScrollView.
/// Trackpad events (precise deltas) pass through untouched.
struct MouseWheelHorizontalScroll: ViewModifier {
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hovering ? install() : remove()
            }
            .onDisappear(perform: remove)
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard !event.hasPreciseScrollingDeltas, let cg = event.cgEvent?.copy() else {
                return event
            }
            let line = cg.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let point = cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let fixed = cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: line)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: point)
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixed)
            return NSEvent(cgEvent: cg) ?? event
        }
    }

    private func remove() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}

extension View {
    func mouseWheelScrollsHorizontally() -> some View {
        modifier(MouseWheelHorizontalScroll())
    }
}
