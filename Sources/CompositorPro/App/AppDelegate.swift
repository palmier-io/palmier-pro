import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

    private(set) var isTerminating = false
    private var restartRequested = false
    private var terminationTask: Task<Void, Never>?
    private var terminationReplySent = false
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    private lazy var windowActivationRestoration = WindowActivationRestoration(
        canRestore: { [weak self] in
            guard let self else { return false }
            return !self.isTerminating && NSApplication.shared.isActive
        },
        restore: { AppState.shared.restoreWindowForActivation(restoringMinimizedWindows: $0) }
    )

    override init() {
        super.init()
    }

    init(windowActivationRestoration: WindowActivationRestoration) {
        super.init()
        self.windowActivationRestoration = windowActivationRestoration
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
        startMemoryPressureMonitoring()

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
        guard !isTerminating else { return false }
        windowActivationRestoration.request(restoringMinimizedWindows: true)
        if !sender.isActive { sender.activate() }
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isTerminating else { return }
        windowActivationRestoration.request(restoringMinimizedWindows: false)
    }

    func applicationWillResignActive(_ notification: Notification) {
        windowActivationRestoration.cancel()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }
        let projects = AppState.shared.openProjects
        let shouldRestart = restartRequested

        // Failsafe watchdog: if graceful termination takes longer than 3 seconds, force exit so Command+Q never hangs.
        // Runs on a background queue so a hung main thread cannot prevent termination.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
            Log.app.warning("Termination hard deadline reached; forcing process exit")
            _exit(0)
        }

        startTermination(projects: projects, prepareServices: { validate in
            Log.app.info("Termination: flushing project registry")
            try await ProjectRegistry.shared.flush()
            try validate()
            if shouldRestart {
                try await Self.scheduleRelaunch(
                    applicationURL: Bundle.main.bundleURL,
                    processID: ProcessInfo.processInfo.processIdentifier
                )
                try validate()
            }
            Log.app.info("Termination: draining skill tasks")
            await SkillStore.shared.prepareForTermination()
            try validate()
            Log.app.info("Termination: stopping MCP service")
            await AppState.shared.stopMCPService()
            try validate()
            Log.app.info("Termination: draining MLX operations")
            if !MLXRuntime.beginTermination() {
                await MLXRuntime.waitUntilIdle()
                try validate()
            }
        }, didClose: { [weak self] in self?.releaseMemory(projects: projects) },
           onError: { sender.presentError($0) },
           sendReply: { sender.reply(toApplicationShouldTerminate: $0) })
        return .terminateLater
    }

    func startTermination(
        projects: [VideoProject],
        prepareServices: @escaping @MainActor (@escaping @MainActor () throws -> Void) async throws -> Void,
        didClose: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (Error) -> Void,
        sendReply: @escaping @MainActor (Bool) -> Void
    ) {
        guard !isTerminating else { return }
        isTerminating = true
        windowActivationRestoration.cancel()
        terminationReplySent = false
        Log.app.info("Termination: saving \(projects.count) open projects")
        let closeOwners = projects.compactMap { project in
            project.beginClosing().map { (project: project, lease: $0) }
        }
        for owner in closeOwners {
            owner.project.editorViewModel.agentService.cancelAllRuns()
        }
        let validateOwners: @MainActor () throws -> Void = {
            try Task.checkCancellation()
            for owner in closeOwners { try owner.project.validateCloseOwner(owner.lease) }
        }

        terminationTask = Task { @MainActor [weak self] in
            guard let self else { return }
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
                try await prepareServices(validateOwners)
                try validateOwners()
                var closeAttempts = 0
                while closeOwners.contains(where: { owner in
                    let coordinator = owner.project.editorViewModel.projectPackageCoordinator
                    return !coordinator.isClosed && !coordinator.canFinishClosing
                }) && closeAttempts < 5 {
                    closeAttempts += 1
                    for owner in closeOwners where !owner.project.editorViewModel.projectPackageCoordinator.isClosed {
                        do { try await owner.project.editorViewModel.projectPackageCoordinator.waitUntilIdle(for: owner.lease) }
                        catch {
                            guard owner.project.editorViewModel.projectPackageCoordinator.isClosed else { throw error }
                            try owner.project.validateCloseOwner(owner.lease)
                        }
                        try validateOwners()
                    }
                }
                try validateOwners()
                for owner in closeOwners where !owner.project.editorViewModel.projectPackageCoordinator.isClosed {
                    try owner.project.closeImmediately(using: owner.lease)
                }
                terminationTask = nil
                didClose()
                self.reply(allow: true, sendReply: sendReply)
            } catch {
                for owner in closeOwners {
                    owner.project.editorViewModel.projectPackageCoordinator.cancelClosing(owner.lease)
                }
                self.restartRequested = false
                self.isTerminating = false
                Log.app.error("Termination failed: \(error.localizedDescription)")
                onError(error)
                self.reply(allow: false, sendReply: sendReply)
            }
        }
    }

    private func startMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.releaseTransientMemory()
        }
        source.resume()
        memoryPressureSource = source
    }

    private func releaseTransientMemory() {
        CustomVideoCompositor.clearCaches()
        TextFrameRenderer.clearCaches()
        LUTLoader.releaseCachedLUTs()
        Task { await HybridFrameCache.shared.reset() }
        for project in AppState.shared.openProjects {
            project.editorViewModel.mediaVisualCache.resetSessionState()
        }
    }

    /// Drops playback, decoders, and rendered-frame caches before the process exits.
    @MainActor
    private func releaseMemory(projects: [VideoProject]) {
        for project in projects {
            project.editorViewModel.releaseMemoryForTermination()
        }
        CustomVideoCompositor.clearCaches()
        TextFrameRenderer.clearCaches()
        LUTLoader.releaseCachedLUTs()
        Task { await HybridFrameCache.shared.reset() }
    }

    /// Replies to a pending termination request exactly once.
    private func reply(allow: Bool, sendReply: (Bool) -> Void) {
        guard !terminationReplySent else { return }
        terminationReplySent = true
        terminationTask = nil
        Log.app.info("Termination: replying allow=\(allow)")
        sendReply(allow)
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
