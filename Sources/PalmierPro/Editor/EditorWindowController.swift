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
            let hitView = self.window?.contentView?.hitTest(event.locationInWindow)
            self.resignStaleFocus(hitView: hitView)
            self.handlePanelClick(hitView: hitView)
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

        if editorViewModel.focusedPanel == .media, !shift,
           let direction = mediaArrowDirection(for: event.keyCode) {
            editorViewModel.moveMediaSelection(direction: direction)
            return true
        }

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

        case 50: // ` (backtick) — toggle panel maximize
            if mods.intersection([.command, .option, .control, .shift]).isEmpty {
                toggleMaximizePanelAction()
                return true
            }
            return false

        case 36: // Return / Enter
            if editorViewModel.cropEditingActive {
                editorViewModel.cropEditingActive = false
                return true
            }
            return false

        case 53: // Escape
            if editorViewModel.cropEditingActive {
                editorViewModel.cropEditingActive = false
                return true
            }
            if editorViewModel.maximizedPanel != nil {
                editorViewModel.maximizedPanel = nil
                return true
            }
            editorViewModel.selectedClipIds.removeAll()
            editorViewModel.toolMode = .pointer
            return true

        default:
            return false
        }
    }

    private func mediaArrowDirection(for keyCode: UInt16) -> EditorViewModel.MediaSelectionDirection? {
        switch keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: nil
        }
    }

    private var isTextInputFocused: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let textView = responder as? NSTextView { return textView.isEditable }
        if let textField = responder as? NSTextField { return textField.isEditable }
        return false
    }

    private func handlePanelClick(hitView: NSView?) {
        var view = hitView
        while let v = view {
            if let panel = EditorViewModel.FocusedPanel(accessibilityID: v.accessibilityIdentifier()) {
                editorViewModel.focusedPanel = panel
                if panel == .media { editorViewModel.selectedClipIds.removeAll() }
                if panel == .timeline { editorViewModel.selectedMediaAssetIds.removeAll() }
                return
            }
            view = v.superview
        }
    }

    /// Clear stale first-responder focus before the click is dispatched.
    private func resignStaleFocus(hitView: NSView?) {
        // Don't disturb a deliberate click into a text input.
        if hitView is NSTextView || hitView is NSTextField { return }
        guard let responder = window?.firstResponder,
              let view = responder as? NSView, view !== window?.contentView else { return }
        window?.makeFirstResponder(nil)
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

    @objc func showKeyboardShortcuts(_ sender: Any?) {
        editorViewModel.helpTab = .shortcuts
        editorViewModel.showHelp = true
    }

    @objc func showMCPInstructions(_ sender: Any?) {
        editorViewModel.helpTab = .mcp
        editorViewModel.showHelp = true
    }

    @objc func toggleMediaPanel(_ sender: Any?) { editorViewModel.mediaPanelVisible.toggle() }
    @objc func toggleInspectorPanel(_ sender: Any?) { editorViewModel.inspectorPanelVisible.toggle() }
    @objc func toggleAgentPanel(_ sender: Any?) { editorViewModel.agentPanelVisible.toggle() }
    @objc func toggleMaximizePanel(_ sender: Any?) { toggleMaximizePanelAction() }

    private func toggleMaximizePanelAction() {
        if editorViewModel.maximizedPanel != nil {
            editorViewModel.maximizedPanel = nil
        } else if let panel = editorViewModel.focusedPanel {
            editorViewModel.maximizedPanel = panel
        }
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleMediaPanel(_:)):
            menuItem.state = editorViewModel.mediaPanelVisible ? .on : .off
            return true
        case #selector(toggleInspectorPanel(_:)):
            menuItem.state = editorViewModel.inspectorPanelVisible ? .on : .off
            return true
        case #selector(toggleAgentPanel(_:)):
            menuItem.state = editorViewModel.agentPanelVisible ? .on : .off
            return true
        case #selector(toggleMaximizePanel(_:)):
            menuItem.state = editorViewModel.maximizedPanel != nil ? .on : .off
            return editorViewModel.maximizedPanel != nil || editorViewModel.focusedPanel != nil
        default:
            return true
        }
    }
}
