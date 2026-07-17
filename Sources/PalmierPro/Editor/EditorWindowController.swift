import AppKit

/// Window controller that handles keyboard shortcuts via the responder chain.
/// Forwards actions to the EditorViewModel owned by VideoProject.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let editorViewModel: EditorViewModel
    var onBecameKey: (() -> Void)?
    private nonisolated(unsafe) var keyMonitor: Any?
    private nonisolated(unsafe) var mouseMonitor: Any?
    private nonisolated(unsafe) var endEditingObserver: Any?

    init(editorViewModel: EditorViewModel, window: NSWindow) {
        self.editorViewModel = editorViewModel
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowDidBecomeKey(_ notification: Notification) {
        onBecameKey?()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let endEditingObserver { NotificationCenter.default.removeObserver(endEditingObserver) }
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

        endEditingObserver = NotificationCenter.default.addObserver(
            forName: NSText.didEndEditingNotification, object: nil, queue: .main
        ) { [weak self] note in
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let self, let editor = object as? NSTextView,
                      editor.window === self.window, let storage = editor.textStorage else { return }
                self.editorViewModel.undo.removeAllActions(withTarget: storage)
            }
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
        let rangeMarkShortcut = mods.intersection([.command, .option, .control]).isEmpty

        if editorViewModel.focusedPanel == .media, !shift,
           let direction = mediaArrowDirection(for: event.keyCode) {
            editorViewModel.moveMediaSelection(direction: direction)
            return true
        }

        switch event.keyCode {
        case 0: // A key
            if editorViewModel.focusedPanel == .timeline,
               mods.intersection([.command, .option, .control]).isEmpty {
                editorViewModel.selectForwardFromCurrentSelection(scope: shift ? .allTracks : .track)
                return true
            }
            return false

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
            if !editorViewModel.selectedFolderIds.isEmpty || !editorViewModel.selectedMediaAssetIds.isEmpty
                || !editorViewModel.selectedTimelineIds.isEmpty {
                if !editorViewModel.selectedFolderIds.isEmpty {
                    editorViewModel.deleteFolders(ids: editorViewModel.selectedFolderIds)
                }
                if !editorViewModel.selectedMediaAssetIds.isEmpty {
                    editorViewModel.deleteSelectedMediaAssets()
                }
                for id in editorViewModel.selectedTimelineIds {
                    editorViewModel.deleteTimeline(id)
                }
                editorViewModel.selectedTimelineIds.removeAll()
            } else if shift {
                if editorViewModel.selectedGap != nil {
                    editorViewModel.rippleDeleteSelectedGap()
                } else {
                    editorViewModel.rippleDeleteSelectedClips()
                }
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

        case 34: // I key
            if rangeMarkShortcut {
                editorViewModel.markTimelineRangeStart()
                return true
            }
            return false

        case 31: // O key
            if rangeMarkShortcut {
                editorViewModel.markTimelineRangeEnd()
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
            if editorViewModel.focusedPanel == .media,
               editorViewModel.selectedFolderIds.count == 1,
               let folderId = editorViewModel.selectedFolderIds.first {
                editorViewModel.mediaPanelOpenFolderId = folderId
                return true
            }
            if editorViewModel.cropEditingActive {
                editorViewModel.cropEditingActive = false
                return true
            }
            return false

        case 53: // Escape
            if editorViewModel.pendingSwapClipId != nil {
                editorViewModel.cancelMediaSwap()
                return true
            }
            if editorViewModel.chromaKeySamplingClipId != nil {
                editorViewModel.cancelChromaKeySampling()
                return true
            }
            if editorViewModel.cropEditingActive {
                editorViewModel.cropEditingActive = false
                return true
            }
            if editorViewModel.maximizedPanel != nil {
                editorViewModel.maximizedPanel = nil
                return true
            }
            editorViewModel.selectedClipIds.removeAll()
            editorViewModel.clearTimelineRange()
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
                if panel == .timeline {
                    editorViewModel.selectedMediaAssetIds.removeAll()
                    editorViewModel.selectedTimelineIds.removeAll()
                    editorViewModel.selectedFolderIds.removeAll()
                }
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
    @objc func selectForwardOnTrack(_ sender: Any?) { editorViewModel.selectForwardFromCurrentSelection(scope: .track) }
    @objc func selectForwardOnAllTracks(_ sender: Any?) { editorViewModel.selectForwardFromCurrentSelection(scope: .allTracks) }
    @objc func deleteSelectedClips(_ sender: Any?) { editorViewModel.deleteSelectedClips() }
    @objc func rippleDeleteSelected(_ sender: Any?) {
        if editorViewModel.selectedGap != nil {
            editorViewModel.rippleDeleteSelectedGap()
        } else {
            editorViewModel.rippleDeleteSelectedClips()
        }
    }
    @objc func importMedia(_ sender: Any?) {
        // Handled by MediaTab directly
    }

    @objc func showExport(_ sender: Any?) {
        editorViewModel.showExportDialog = true
    }

    @objc func copy(_ sender: Any?) {
        guard canHandleClipboardShortcut(),
              !editorViewModel.selectedClipIds.isEmpty else { return }
        editorViewModel.copySelectedClipsToClipboard()
    }

    @objc func cut(_ sender: Any?) {
        guard canHandleClipboardShortcut(),
              !editorViewModel.selectedClipIds.isEmpty else { return }
        editorViewModel.copySelectedClipsToClipboard()
        editorViewModel.deleteSelectedClips()
    }

    @objc func paste(_ sender: Any?) {
        if editorViewModel.focusedPanel == .media {
            editorViewModel.mediaPanelPasteRequestTick &+= 1
            return
        }
        guard canHandleClipboardShortcut(),
              editorViewModel.canPasteClips else { return }
        editorViewModel.pasteClipsAtPlayhead()
    }

    private func canHandleClipboardShortcut() -> Bool {
        editorViewModel.focusedPanel == .timeline
    }

    @objc func toggleMediaPanel(_ sender: Any?) { editorViewModel.mediaPanelVisible.toggle() }
    @objc func toggleInspectorPanel(_ sender: Any?) { editorViewModel.inspectorPanelVisible.toggle() }
    @objc func toggleAgentPanel(_ sender: Any?) { editorViewModel.agentPanelVisible.toggle() }
    @objc func toggleMaximizePanel(_ sender: Any?) { toggleMaximizePanelAction() }
    @objc func setLayoutDefault(_ sender: Any?) { editorViewModel.layoutPreset = .default }
    @objc func setLayoutMedia(_ sender: Any?) { editorViewModel.layoutPreset = .media }
    @objc func setLayoutVertical(_ sender: Any?) { editorViewModel.layoutPreset = .vertical }

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
        case #selector(setLayoutDefault(_:)):
            menuItem.state = editorViewModel.layoutPreset == .default ? .on : .off
            return true
        case #selector(setLayoutMedia(_:)):
            menuItem.state = editorViewModel.layoutPreset == .media ? .on : .off
            return true
        case #selector(setLayoutVertical(_:)):
            menuItem.state = editorViewModel.layoutPreset == .vertical ? .on : .off
            return true
        case #selector(copy(_:)), #selector(cut(_:)):
            return canHandleClipboardShortcut() && !editorViewModel.selectedClipIds.isEmpty
        case #selector(selectForwardOnTrack(_:)), #selector(selectForwardOnAllTracks(_:)):
            return editorViewModel.focusedPanel == .timeline && !editorViewModel.selectedClipIds.isEmpty
        case #selector(paste(_:)):
            if editorViewModel.focusedPanel == .media {
                return MediaTab.clipboardHasImportableMedia()
            }
            return canHandleClipboardShortcut() && editorViewModel.canPasteClips
        default:
            return true
        }
    }
}
