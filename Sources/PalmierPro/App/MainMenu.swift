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
        let menu = NSMenu(title: "Palmier Pro")
        menu.addItem(withTitle: "About Palmier Pro", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let updatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(Updater.checkForUpdates(_:)), keyEquivalent: "")
        updatesItem.target = Updater.shared
        menu.addItem(updatesItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings...", action: #selector(NSApplication.sendAction(_:to:from:)), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Palmier Pro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = menu
        return item
    }

    // MARK: - File menu

    private static func fileMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "New", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        menu.addItem(withTitle: "Open...", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        menu.addItem(withTitle: "Save As...", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        menu.addItem(.separator())

        let importItem = NSMenuItem(title: "Import Media...", action: #selector(EditorActions.importMedia(_:)), keyEquivalent: "i")
        importItem.keyEquivalentModifierMask = [.command]
        menu.addItem(importItem)

        menu.addItem(.separator())

        let exportItem = NSMenuItem(title: "Export...", action: #selector(EditorActions.showExport(_:)), keyEquivalent: "e")
        exportItem.keyEquivalentModifierMask = [.command]
        menu.addItem(exportItem)

        item.submenu = menu
        return item
    }

    // MARK: - Edit menu

    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())

        let splitItem = NSMenuItem(title: "Split at Playhead", action: #selector(EditorActions.splitAtPlayhead(_:)), keyEquivalent: "k")
        splitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(splitItem)

        let trimStartItem = NSMenuItem(title: "Trim Start to Playhead", action: #selector(EditorActions.trimStartToPlayhead(_:)), keyEquivalent: "q")
        trimStartItem.keyEquivalentModifierMask = []
        menu.addItem(trimStartItem)

        let trimEndItem = NSMenuItem(title: "Trim End to Playhead", action: #selector(EditorActions.trimEndToPlayhead(_:)), keyEquivalent: "w")
        trimEndItem.keyEquivalentModifierMask = []
        menu.addItem(trimEndItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: "Delete", action: #selector(EditorActions.deleteSelectedClips(_:)), keyEquivalent: "\u{8}") // backspace
        deleteItem.keyEquivalentModifierMask = []
        menu.addItem(deleteItem)

        item.submenu = menu
        return item
    }

    // MARK: - View menu

    private static func viewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")

        let mediaItem = NSMenuItem(title: "Media Panel", action: #selector(EditorActions.toggleMediaPanel(_:)), keyEquivalent: "0")
        mediaItem.keyEquivalentModifierMask = [.command]
        menu.addItem(mediaItem)

        let inspectorItem = NSMenuItem(title: "Inspector", action: #selector(EditorActions.toggleInspectorPanel(_:)), keyEquivalent: "0")
        inspectorItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(inspectorItem)

        let agentItem = NSMenuItem(title: "Agent Panel", action: #selector(EditorActions.toggleAgentPanel(_:)), keyEquivalent: "a")
        agentItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(agentItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        item.submenu = menu
        return item
    }

    // MARK: - Help menu

    private static func helpMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        menu.addItem(withTitle: "Keyboard Shortcuts", action: #selector(EditorActions.showKeyboardShortcuts(_:)), keyEquivalent: "?")
        item.submenu = menu
        return item
    }
}

/// Actions dispatched through the responder chain to reach the active EditorViewModel.
@MainActor @objc protocol EditorActions {
    func splitAtPlayhead(_ sender: Any?)
    func trimStartToPlayhead(_ sender: Any?)
    func trimEndToPlayhead(_ sender: Any?)
    func deleteSelectedClips(_ sender: Any?)
    func importMedia(_ sender: Any?)
    func playPause(_ sender: Any?)
    func stepFrameForward(_ sender: Any?)
    func stepFrameBackward(_ sender: Any?)
    func skipFramesForward(_ sender: Any?)
    func skipFramesBackward(_ sender: Any?)
    func showExport(_ sender: Any?)
    func showKeyboardShortcuts(_ sender: Any?)
    func toggleMediaPanel(_ sender: Any?)
    func toggleInspectorPanel(_ sender: Any?)
    func toggleAgentPanel(_ sender: Any?)
}
