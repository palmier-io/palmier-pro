import SwiftUI
import UniformTypeIdentifiers

struct ProjectOpenOptions {
    var startTutorial = false
}

enum ProjectError: LocalizedError {
    case nameTaken(URL)
    case invalidName(String)

    var errorDescription: String? {
        switch self {
        case .nameTaken(let url):
            "A project named “\(url.deletingPathExtension().lastPathComponent)” already exists in that folder. Pick another name."
        case .invalidName(let name):
            "“\(name)” isn't a valid project name. Use a plain name without slashes or path components."
        }
    }
}

@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    private(set) var activeProject: VideoProject?

    var openProjects: [VideoProject] {
        NSDocumentController.shared.documents.compactMap { $0 as? VideoProject }
    }

    private(set) var mcpService: MCPService?

    func startMCPService() {
        guard mcpService == nil else { return }
        guard MCPService.isEnabledPreference else {
            Log.mcp.notice("mcp disabled in settings; not starting")
            return
        }
        let service = MCPService(projectProvider: { [weak self] in
            self?.activeProject
        })
        service.start()
        mcpService = service
    }

    func stopMCPService() {
        mcpService?.stop()
        mcpService = nil
    }

    func setMCPEnabled(_ enabled: Bool) {
        MCPService.isEnabledPreference = enabled
        if enabled {
            startMCPService()
        } else {
            stopMCPService()
        }
    }

    func showHome() {
        guard let project = activeProject else {
            HomeWindowController.shared.showWindow(nil)
            return
        }
        let presentHome = {
            if let url = project.fileURL {
                ProjectRegistry.shared.register(url)
            }
            project.windowControllers.forEach { $0.window?.orderOut(nil) }
            if self.activeProject === project {
                self.activeProject = nil
            }
            HomeWindowController.shared.showWindow(nil)
        }
        if project.isDocumentEdited {
            project.autosave(withImplicitCancellability: false) { _ in
                DispatchQueue.main.async {
                    presentHome()
                }
            }
        } else {
            presentHome()
        }
    }

    func showEditor(for project: VideoProject) {
        activateProject(project)
        project.showWindows()
    }

    func activateProject(_ project: VideoProject) {
        if activeProject !== project {
            activeProject = project
            project.editorViewModel.refreshProjectId()
            recordProjectActive(project)
        }
        HomeWindowController.shared.window?.orderOut(nil)
    }

    // Save and close project; switch to next open or show Home. Throws (without closing) if the save fails.
    func closeProject(_ project: VideoProject) async throws {
        if let url = project.fileURL { ProjectRegistry.shared.register(url) }
        try await project.saveBeforeClosing()
        let wasActive = activeProject === project
        project.close()
        if wasActive {
            activeProject = nil
            if let next = openProjects.first {
                showEditor(for: next)
            } else {
                HomeWindowController.shared.showWindow(nil)
            }
        }
    }

    func revealGeneratedAssetFromNotification(assetId: String?, projectURL: URL?) {
        NSApp.activate(ignoringOtherApps: true)
        guard let project = notificationTargetProject(assetId: assetId, projectURL: projectURL) else {
            if activeProject == nil {
                HomeWindowController.shared.showWindow(nil)
            }
            return
        }

        activeProject = project
        HomeWindowController.shared.window?.orderOut(nil)
        project.showWindows()
        project.windowControllers.first?.window?.makeKeyAndOrderFront(nil)

        guard let assetId,
              let asset = project.editorViewModel.mediaAssets.first(where: { $0.id == assetId }) else {
            return
        }

        let editor = project.editorViewModel
        editor.mediaPanelVisible = true
        editor.maximizedPanel = nil
        editor.focusedPanel = .media
        editor.selectMediaAsset(asset)
        editor.mediaPanelRevealAssetId = assetId
    }

    private func notificationTargetProject(assetId: String?, projectURL: URL?) -> VideoProject? {
        if let projectURL {
            return openProjects.first { Self.sameFile($0.fileURL, projectURL) }
        }
        if let assetId {
            return openProjects.first { project in
                project.editorViewModel.mediaAssets.contains { $0.id == assetId }
            }
        }
        return activeProject
    }

    private static func sameFile(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    // MARK: - Project lifecycle

    // Creates and displays a project at `url`; doesn't save or register.
    private func instantiateProject(at url: URL) -> VideoProject {
        let doc = VideoProject()
        doc.fileURL = url
        doc.fileType = VideoProject.typeIdentifier
        doc.makeWindowControllers()
        doc.showWindows()
        NSDocumentController.shared.addDocument(doc)
        return doc
    }

    /// Creates a new project in the storage folder; errors if the name is invalid or already taken.
    @discardableResult
    func createProject(named name: String) async throws -> VideoProject {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? Project.defaultProjectName : trimmed
        guard !base.contains("/"), !base.contains("\\"), base != ".", base != ".." else {
            throw ProjectError.invalidName(base)
        }
        let directory = Project.storageDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(base).appendingPathExtension(Project.fileExtension)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectError.nameTaken(url)
        }
        let previous = activeProject
        let doc = instantiateProject(at: url)
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                doc.save(to: url, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
        } catch {
            doc.close()
            try? FileManager.default.removeItem(at: url)
            if let previous { showEditor(for: previous) }
            throw error
        }
        ProjectRegistry.shared.register(url)
        doc.editorViewModel.refreshProjectId()
        recordProjectCreated(doc)
        recordProjectOpened(doc)
        return doc
    }

    func createProjectInteractively() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.projectContentType]
        panel.nameFieldStringValue = Project.defaultProjectName
        panel.directoryURL = Project.storageDirectory
        panel.title = "New Project"
        panel.begin { [self] response in
            guard response == .OK, let url = panel.url else { return }
            let doc = instantiateProject(at: url)
            doc.save(to: url, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                guard error == nil else { return }
                ProjectRegistry.shared.register(url)
                doc.editorViewModel.refreshProjectId()
                self.recordProjectCreated(doc)
                self.recordProjectOpened(doc)
            }
        }
    }

    func openProject(at url: URL, register: Bool = true, options: ProjectOpenOptions = .init()) {
        Task {
            do {
                try await openProjectAsync(at: url, register: register, options: options)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @discardableResult
    func openProjectAsync(at url: URL, register: Bool = true, options: ProjectOpenOptions = .init()) async throws -> VideoProject {
        let resolved = url.standardizedFileURL
        if let existing = showExistingProject(at: resolved, register: register, options: options) {
            return existing
        }
        let doc = try await VideoProject.load(from: resolved)
        if let existing = showExistingProject(at: resolved, register: register, options: options) {
            return existing
        }

        doc.makeWindowControllers()
        doc.showWindows()
        NSDocumentController.shared.addDocument(doc)
        if register { ProjectRegistry.shared.register(resolved) }
        doc.editorViewModel.refreshProjectId()
        recordProjectOpened(doc)
        apply(options, to: doc.editorViewModel)
        return doc
    }

    private func showExistingProject(at url: URL, register: Bool, options: ProjectOpenOptions) -> VideoProject? {
        if let existing = openProjects.first(where: { Self.sameFile($0.fileURL, url) }) {
            if register { ProjectRegistry.shared.register(url) }
            showEditor(for: existing)
            apply(options, to: existing.editorViewModel)
            return existing
        }
        return nil
    }

    private func recordProjectCreated(_ project: VideoProject) {
        Analytics.capture(.projectCreated, properties: project.editorViewModel.analyticsSnapshot())
    }

    private func recordProjectOpened(_ project: VideoProject) {
        let properties = project.editorViewModel.analyticsSnapshot()
        Analytics.capture(.projectOpened, properties: properties)
        if let projectId = project.editorViewModel.projectId {
            Analytics.captureProjectActive(projectId: projectId, properties: properties)
        }
    }

    private func recordProjectActive(_ project: VideoProject) {
        guard let projectId = project.editorViewModel.projectId else { return }
        let properties = project.editorViewModel.analyticsSnapshot()
        Analytics.captureProjectActive(projectId: projectId, properties: properties)
    }

    private func apply(_ options: ProjectOpenOptions, to editor: EditorViewModel) {
        if options.startTutorial {
            DispatchQueue.main.async { editor.tour.start(in: editor) }
        }
    }

    func openSample(slug: String, startTutorial: Bool, onProgress: @escaping (Double) -> Void = { _ in }) async throws {
        let options = ProjectOpenOptions(startTutorial: startTutorial)
        if let cached = SampleProjectService.shared.cachedURL(slug: slug) {
            try await openProjectAsync(at: cached, register: false, options: options)
            return
        }
        let url = try await SampleProjectService.shared.materialize(slug: slug, onProgress: onProgress)
        try await openProjectAsync(at: url, register: false, options: options)
    }

    func openProjectFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.projectContentType]
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Open Project"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            AppState.shared.openProject(at: url)
        }
    }

    private static let projectContentType: UTType = {
        UTType(Project.typeIdentifier)
            ?? UTType(filenameExtension: Project.fileExtension, conformingTo: .package)
            ?? .package
    }()

}
