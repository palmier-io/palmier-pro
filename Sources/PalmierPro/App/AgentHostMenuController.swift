import AppKit

@MainActor
final class AgentHostMenuController: NSObject, NSMenuDelegate {
    static let shared = AgentHostMenuController()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    private override init() {
        super.init()
    }

    func start() {
        guard statusItem.menu == nil else { return }

        let description = AppIdentity.name
        statusItem.button?.image = NSImage(systemSymbolName: "film.stack", accessibilityDescription: description)
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = description
        menu.delegate = self
        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowVisibilityChanged),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowVisibilityChanged),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let statusItem = NSMenuItem(title: L10n.string("MCP Server"), action: nil, keyEquivalent: "")
        statusItem.state = AppState.shared.mcpService?.isRunning == true ? .on : .off
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(.separator())

        addItem(AppIdentity.name, action: #selector(showHome))
        addItem(L10n.string("Open Project"), action: #selector(openProject))

        let projects = AppState.shared.openProjects
        if !projects.isEmpty {
            let projectsItem = NSMenuItem(title: L10n.string("My Projects"), action: nil, keyEquivalent: "")
            let projectsMenu = NSMenu()
            for project in projects {
                let item = NSMenuItem(
                    title: project.displayName ?? Project.defaultProjectName,
                    action: #selector(showProject(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = project
                projectsMenu.addItem(item)
            }
            projectsItem.submenu = projectsMenu
            menu.addItem(projectsItem)
        }

        menu.addItem(.separator())
        addItem(L10n.string("Settings…"), action: #selector(showSettings))
        menu.addItem(.separator())
        addItem(L10n.string("Quit Palmier Pro"), action: #selector(quit))
    }

    private func addItem(_ title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func showHome() {
        AppState.shared.showHome()
    }

    @objc private func openProject() {
        AppState.shared.openProjectFromPanel()
    }

    @objc private func showProject(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? VideoProject else { return }
        AppState.shared.showEditor(for: project)
    }

    @objc private func showSettings() {
        AppState.shared.presentApplicationUI()
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func refreshActivationPolicy() {
        DispatchQueue.main.async {
            let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && $0.level == .normal }
            if !hasVisibleWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        refreshActivationPolicy()
    }
}
