import AppKit

extension EditorSplitViewController {
    /// Publish the current tour step's target frame
    /// `stepIndex` selects the step. `anchorRevision` isn't read here — the caller
    /// passes it only so its read registers a SwiftUI observation dependency, so this
    /// re-runs when an anchored control re-lays out inside a panel
    func updateTourFrame(stepIndex: Int? = nil, anchorRevision: Int = 0) {
        let tour = editor.tour
        let index = stepIndex ?? tour.stepIndex
        guard let index, tour.steps.indices.contains(index),
              case .spotlight(let target) = tour.steps[index].kind,
              let frame = tourFrame(for: target) else {
            if tour.targetFrame != nil { tour.targetFrame = nil }
            return
        }
        if tour.targetFrame != frame { tour.targetFrame = frame }
    }

    private func tourFrame(for target: TourTarget) -> CGRect? {
        switch target {
        case .panel(let panel):
            return flippedFrame(of: leafItem(for: panel)?.viewController.view)
        case .element(let id):
            return flippedFrame(of: editor.tour.anchorViews[id]?.value)
        }
    }

    /// A view's frame in the full window content coords, flipped to top-left origin.
    private func flippedFrame(of source: NSView?) -> CGRect? {
        guard let source, source.window != nil,
              let windowContent = source.window?.contentView,
              source.bounds.width > 1, source.bounds.height > 1 else { return nil }
        let r = source.convert(source.bounds, to: windowContent)
        let top = windowContent.isFlipped ? r.minY : windowContent.bounds.height - r.maxY
        return CGRect(
            x: r.minX,
            y: top,
            width: r.width,
            height: r.height
        )
    }
}
