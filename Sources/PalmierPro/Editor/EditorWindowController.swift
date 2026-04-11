import AppKit

/// Window controller that handles keyboard shortcuts via the responder chain.
/// Forwards actions to the EditorViewModel owned by VideoProject.
final class EditorWindowController: NSWindowController {
    let editorViewModel: EditorViewModel
    private nonisolated(unsafe) var keyMonitor: Any?
    private nonisolated(unsafe) var mouseMonitor: Any?

    init(editorViewModel: EditorViewModel, window: NSWindow) {
        self.editorViewModel = editorViewModel
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            return self.handleKeyDown(event) ? nil : event
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            self.resignTextFocusIfNeeded(for: event)
            return event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // Don't intercept keys when a text field has focus
        if isTextInputFocused {
            return false
        }

        let mods = event.modifierFlags
        let shift = mods.contains(.shift)
        let cmd = mods.contains(.command)

        switch event.keyCode {
        case 49: // Space
            editorViewModel.togglePlayback()
            return true

        case 123: // Left arrow
            if shift { editorViewModel.skipBackward() } else { editorViewModel.stepBackward() }
            return true

        case 124: // Right arrow
            if shift { editorViewModel.skipForward() } else { editorViewModel.stepForward() }
            return true

        case 51: // Delete/Backspace
            if !editorViewModel.selectedMediaAssetIds.isEmpty {
                editorViewModel.deleteSelectedMediaAssets()
            } else if shift {
                editorViewModel.rippleDeleteSelectedClips()
            } else {
                editorViewModel.deleteSelectedClips()
            }
            return true

        case 8: // C key
            if !cmd {
                editorViewModel.toolMode = .razor
                return true
            }
            return false

        case 9: // V key
            if !cmd {
                editorViewModel.toolMode = .pointer
                return true
            }
            return false

        case 33: // [ key
            editorViewModel.trimStartToPlayhead()
            return true

        case 30: // ] key
            editorViewModel.trimEndToPlayhead()
            return true

        case 53: // Escape
            editorViewModel.selectedClipIds.removeAll()
            editorViewModel.toolMode = .pointer
            return true

        default:
            return false
        }
    }

    private var isTextInputFocused: Bool {
        if let responder = window?.firstResponder {
            responder is NSTextView || responder is NSTextField
        } else {
            false
        }
    }

    private func resignTextFocusIfNeeded(for event: NSEvent) {
        guard window?.firstResponder is NSTextView else { return }
        let hitView = window?.contentView?.hitTest(event.locationInWindow)
        if !(hitView is NSTextView || hitView is NSTextField) {
            window?.makeFirstResponder(nil)
        }
    }
}

// MARK: - EditorActions (responder chain)

extension EditorWindowController: EditorActions {
    @objc func splitAtPlayhead(_ sender: Any?) { editorViewModel.splitAtPlayhead() }
    @objc func trimStartToPlayhead(_ sender: Any?) { editorViewModel.trimStartToPlayhead() }
    @objc func trimEndToPlayhead(_ sender: Any?) { editorViewModel.trimEndToPlayhead() }
    @objc func deleteSelectedClips(_ sender: Any?) { editorViewModel.deleteSelectedClips() }
    @objc func playPause(_ sender: Any?) { editorViewModel.togglePlayback() }
    @objc func stepFrameForward(_ sender: Any?) { editorViewModel.stepForward() }
    @objc func stepFrameBackward(_ sender: Any?) { editorViewModel.stepBackward() }
    @objc func skipFramesForward(_ sender: Any?) { editorViewModel.skipForward() }
    @objc func skipFramesBackward(_ sender: Any?) { editorViewModel.skipBackward() }

    @objc func importMedia(_ sender: Any?) {
        // Handled by MediaPanelView directly
    }

    @objc func showExport(_ sender: Any?) {
        editorViewModel.showExportDialog = true
    }
}
