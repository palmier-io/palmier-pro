import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

    private(set) var isTerminating = false
    private var restartRequested = false
    private var terminationTask: Task<Void, Never>?

    private override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Activate the app (required when launched from CLI, not a .app bundle)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Start Sparkle updater
        _ = Updater.shared

        HomeWindowController.shared.showWindow(nil)
        SkillStore.shared.startSkillSync()
        Task.detached(priority: .utility) {
            Project.ensureStorageDirectory()
        }

        AppNotifications.configure()

        AppState.shared.startMCPService()

        // Pre-warm NSOpenPanel to avoid main thread blocking during cold start.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !self.isTerminating else { return }
            _ = NSOpenPanel()
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppState.shared.showHome()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }
        isTerminating = true
        let projects = AppState.shared.openProjects
        let shouldRestart = restartRequested
        let closeOwners = projects.compactMap { project in
            project.beginClosing().map { (project: project, lease: $0) }
        }
        let validateOwners = {
            try Task.checkCancellation()
            for owner in closeOwners { try owner.project.validateCloseOwner(owner.lease) }
        }

        terminationTask = Task { @MainActor in
            do {
                for owner in closeOwners {
                    if !owner.project.editorViewModel.projectPackageCoordinator.isClosed {
                        do { try await owner.project.saveBeforeClosing(using: owner.lease) }
                        catch {
                            guard owner.project.editorViewModel.projectPackageCoordinator.isClosed else { throw error }
                            try owner.project.validateCloseOwner(owner.lease)
                        }
                    }
                    try validateOwners()
                }
                try await ProjectRegistry.shared.flush()
                try validateOwners()
                if shouldRestart {
                    try await Self.scheduleRelaunch(
                        applicationURL: Bundle.main.bundleURL,
                        processID: ProcessInfo.processInfo.processIdentifier
                    )
                    try validateOwners()
                }
                await SkillStore.shared.prepareForTermination()
                AppState.shared.stopMCPService()
                try validateOwners()
                if !MLXRuntime.beginTermination() {
                    await MLXRuntime.waitUntilIdle()
                    try validateOwners()
                }
                repeat {
                    for owner in closeOwners where !owner.project.editorViewModel.projectPackageCoordinator.isClosed {
                        do { try await owner.project.editorViewModel.projectPackageCoordinator.waitUntilIdle(for: owner.lease) }
                        catch {
                            guard owner.project.editorViewModel.projectPackageCoordinator.isClosed else { throw error }
                            try owner.project.validateCloseOwner(owner.lease)
                        }
                        try validateOwners()
                    }
                } while closeOwners.contains { owner in
                    let coordinator = owner.project.editorViewModel.projectPackageCoordinator
                    return !coordinator.isClosed && !coordinator.canFinishClosing
                }
                try validateOwners()
                for owner in closeOwners where !owner.project.editorViewModel.projectPackageCoordinator.isClosed {
                    try owner.project.closeImmediately(using: owner.lease)
                }
                terminationTask = nil
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                for owner in closeOwners {
                    owner.project.editorViewModel.projectPackageCoordinator.cancelClosing(owner.lease)
                }
                terminationTask = nil
                restartRequested = false
                isTerminating = false
                sender.presentError(error)
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    func restart() {
        guard !isTerminating else { return }
        restartRequested = true
        NSApp.terminate(nil)
    }

    @concurrent
    private static func scheduleRelaunch(applicationURL: URL, processID: Int32) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open -n \"$2\"",
            "compositor-restart",
            String(processID),
            applicationURL.path,
        ]
        try process.run()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Auth callbacks belonged to the removed hosted backend (R1): ignore deep links.
        for url in urls {
            Log.account.notice(
                "ignored deep link url=\(Self.safeURLDescription(url))",
                data: ["url": Self.safeURLDescription(url)])
        }
    }

    private static func safeURLDescription(_ url: URL) -> String {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.path = url.path
        return components.string ?? url.scheme ?? "unknown"
    }

    @MainActor
    @objc func newProject(_ sender: Any?) {
        AppState.shared.createProjectInteractively()
    }

    @MainActor
    @objc func openProject(_ sender: Any?) {
        AppState.shared.openProjectFromPanel()
    }

    @MainActor
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @MainActor
    @objc func showFeatures(_ sender: Any?) {
        HelpWindowController.shared.show(tab: .features)
    }

    @MainActor
    @objc func showKeyboardShortcuts(_ sender: Any?) {
        HelpWindowController.shared.show(tab: .shortcuts)
    }

    @MainActor
    @objc func showMCPInstructions(_ sender: Any?) {
        HelpWindowController.shared.show(tab: .mcp)
    }

    @MainActor
    @objc func showFeedback(_ sender: Any?) {
        FeedbackWindowController.shared.show()
    }

    @MainActor
    @objc func showTutorial(_ sender: Any?) {
        guard let editor = AppState.shared.activeProject?.editorViewModel else { return }
        editor.tour.start(in: editor)
    }
}
