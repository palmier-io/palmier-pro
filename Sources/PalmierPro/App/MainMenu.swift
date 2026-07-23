import AppKit

/// Builds the application main menu with keyboard shortcuts.
/// Called from AppDelegate to wire shortcuts into the responder chain.
@MainActor
enum MainMenuBuilder {

    static func buildMenu() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenu())
        mainMenu.addItem(fileMenu())
        mainMenu.addItem(editMenu())
        mainMenu.addItem(viewMenu())
        mainMenu.addItem(helpMenu())
        return mainMenu
    }

    // MARK: - App menu

    private static func appMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.string("Palmier Pro"))
        menu.addItem(withTitle: L10n.string("About Palmier Pro"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let updatesItem = NSMenuItem(title: L10n.string("Check for Updates…"), action: #selector(Updater.checkForUpdates(_:)), keyEquivalent: "")
        updatesItem.target = Updater.shared
        menu.addItem(updatesItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("Settings…"), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("Quit Palmier Pro"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = menu
        return item
    }

    // MARK: - File menu

    private static func fileMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.string("File"))
        let newItem = menu.addItem(withTitle: L10n.string("New"), action: #selector(AppDelegate.newProject(_:)), keyEquivalent: "n")
        newItem.target = NSApp.delegate
        let openItem = menu.addItem(withTitle: L10n.string("Open…"), action: #selector(AppDelegate.openProject(_:)), keyEquivalent: "o")
        openItem.target = NSApp.delegate
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("Save"), action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        menu.addItem(withTitle: L10n.string("Save As…"), action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        menu.addItem(.separator())

        let importItem = NSMenuItem(title: L10n.string("Import Media…"), action: #selector(EditorActions.importMedia(_:)), keyEquivalent: "i")
        importItem.keyEquivalentModifierMask = [.command]
        menu.addItem(importItem)

        menu.addItem(.separator())

        let exportItem = NSMenuItem(title: L10n.string("Export…"), action: #selector(EditorActions.showExport(_:)), keyEquivalent: "e")
        exportItem.keyEquivalentModifierMask = [.command]
        menu.addItem(exportItem)

        item.submenu = menu
        return item
    }

    // MARK: - Edit menu

    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.string("Edit"))
        menu.addItem(withTitle: L10n.string("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: L10n.string("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: L10n.string("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: L10n.string("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: L10n.string("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())

        let selectForwardTrackItem = NSMenuItem(title: L10n.string("Select Forward on Track"), action: #selector(EditorActions.selectForwardOnTrack(_:)), keyEquivalent: "a")
        selectForwardTrackItem.keyEquivalentModifierMask = []
        menu.addItem(selectForwardTrackItem)

        let selectForwardAllItem = NSMenuItem(title: L10n.string("Select Forward on All Tracks"), action: #selector(EditorActions.selectForwardOnAllTracks(_:)), keyEquivalent: "a")
        selectForwardAllItem.keyEquivalentModifierMask = [.shift]
        menu.addItem(selectForwardAllItem)

        menu.addItem(.separator())

        let splitItem = NSMenuItem(title: L10n.string("Split at Playhead"), action: #selector(EditorActions.splitAtPlayhead(_:)), keyEquivalent: "k")
        splitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(splitItem)

        let trimStartItem = NSMenuItem(title: L10n.string("Trim Start to Playhead"), action: #selector(EditorActions.trimStartToPlayhead(_:)), keyEquivalent: "q")
        trimStartItem.keyEquivalentModifierMask = []
        menu.addItem(trimStartItem)

        let trimEndItem = NSMenuItem(title: L10n.string("Trim End to Playhead"), action: #selector(EditorActions.trimEndToPlayhead(_:)), keyEquivalent: "w")
        trimEndItem.keyEquivalentModifierMask = []
        menu.addItem(trimEndItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: L10n.string("Delete"), action: #selector(EditorActions.deleteSelectedClips(_:)), keyEquivalent: "\u{8}") // backspace
        deleteItem.keyEquivalentModifierMask = []
        menu.addItem(deleteItem)

        let rippleDeleteItem = NSMenuItem(title: L10n.string("Ripple Delete"), action: #selector(EditorActions.rippleDeleteSelected(_:)), keyEquivalent: "\u{8}") // backspace
        rippleDeleteItem.keyEquivalentModifierMask = [.shift]
        menu.addItem(rippleDeleteItem)

        item.submenu = menu
        return item
    }

    // MARK: - View menu

    private static func viewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.string("View"))

        let mediaItem = NSMenuItem(title: L10n.string("Media Panel"), action: #selector(EditorActions.toggleMediaPanel(_:)), keyEquivalent: "0")
        mediaItem.keyEquivalentModifierMask = [.command]
        menu.addItem(mediaItem)

        let inspectorItem = NSMenuItem(title: L10n.string("Inspector"), action: #selector(EditorActions.toggleInspectorPanel(_:)), keyEquivalent: "0")
        inspectorItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(inspectorItem)

        let agentItem = NSMenuItem(title: L10n.string("Agent Panel"), action: #selector(EditorActions.toggleAgentPanel(_:)), keyEquivalent: "a")
        agentItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(agentItem)

        menu.addItem(.separator())

        let maximizeItem = NSMenuItem(title: L10n.string("Maximize Focused Panel"), action: #selector(EditorActions.toggleMaximizePanel(_:)), keyEquivalent: "`")
        maximizeItem.keyEquivalentModifierMask = []
        menu.addItem(maximizeItem)

        menu.addItem(.separator())
        menu.addItem(layoutSubmenuItem())
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        item.submenu = menu
        return item
    }

    private static func layoutSubmenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.string("Layout"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: L10n.string("Layout"))

        let defaultItem = NSMenuItem(title: L10n.string(LayoutPreset.default.label), action: #selector(EditorActions.setLayoutDefault(_:)), keyEquivalent: "1")
        defaultItem.keyEquivalentModifierMask = [.command]
        submenu.addItem(defaultItem)

        let mediaItem = NSMenuItem(title: L10n.string(LayoutPreset.media.label), action: #selector(EditorActions.setLayoutMedia(_:)), keyEquivalent: "2")
        mediaItem.keyEquivalentModifierMask = [.command]
        submenu.addItem(mediaItem)

        let verticalItem = NSMenuItem(title: L10n.string(LayoutPreset.vertical.label), action: #selector(EditorActions.setLayoutVertical(_:)), keyEquivalent: "3")
        verticalItem.keyEquivalentModifierMask = [.command]
        submenu.addItem(verticalItem)

        item.submenu = submenu
        return item
    }

    // MARK: - Help menu

    private static func helpMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.string("Help"))
        menu.addItem(withTitle: L10n.string("Tutorial"), action: #selector(AppDelegate.showTutorial(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("Keyboard Shortcuts"), action: #selector(AppDelegate.showKeyboardShortcuts(_:)), keyEquivalent: "?")
        menu.addItem(withTitle: L10n.string("MCP Instructions"), action: #selector(AppDelegate.showMCPInstructions(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("Send Feedback…"), action: #selector(AppDelegate.showFeedback(_:)), keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// Actions dispatched through the responder chain to reach the active EditorViewModel.
@MainActor @objc protocol EditorActions {
    func splitAtPlayhead(_ sender: Any?)
    func trimStartToPlayhead(_ sender: Any?)
    func trimEndToPlayhead(_ sender: Any?)
    func selectForwardOnTrack(_ sender: Any?)
    func selectForwardOnAllTracks(_ sender: Any?)
    func deleteSelectedClips(_ sender: Any?)
    func rippleDeleteSelected(_ sender: Any?)
    func importMedia(_ sender: Any?)
    func showExport(_ sender: Any?)
    func toggleMediaPanel(_ sender: Any?)
    func toggleInspectorPanel(_ sender: Any?)
    func toggleAgentPanel(_ sender: Any?)
    func toggleMaximizePanel(_ sender: Any?)
    func setLayoutDefault(_ sender: Any?)
    func setLayoutMedia(_ sender: Any?)
    func setLayoutVertical(_ sender: Any?)
}
