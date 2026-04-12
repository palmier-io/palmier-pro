import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    private(set) var activeProject: VideoProject?

    func showHome() {
        guard let project = activeProject else {
            HomeWindowController.shared.showWindow(nil)
            return
        }
        if project.isDocumentEdited {
            project.autosave(withImplicitCancellability: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.activeProject?.windowControllers.forEach { $0.window?.orderOut(nil) }
                    self?.activeProject = nil
                    HomeWindowController.shared.showWindow(nil)
                }
            }
        } else {
            activeProject?.windowControllers.forEach { $0.window?.orderOut(nil) }
            activeProject = nil
            HomeWindowController.shared.showWindow(nil)
        }
    }

    func showEditor(for project: VideoProject) {
        activeProject = project
        HomeWindowController.shared.window?.orderOut(nil)
        project.showWindows()
    }

    // MARK: - Project lifecycle

    func createNewProject() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: Project.fileExtension)!]
        panel.nameFieldStringValue = Project.defaultProjectName
        panel.directoryURL = Project.storageDirectory
        panel.title = "New Project"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let doc = VideoProject()
            doc.fileURL = url
            doc.fileType = VideoProject.typeIdentifier
            doc.makeWindowControllers()
            doc.showWindows()
            NSDocumentController.shared.addDocument(doc)
            doc.save(to: url, ofType: VideoProject.typeIdentifier, for: .saveOperation) { _ in
                ProjectRegistry.shared.register(url)
            }
        }
    }

    func openProject(at url: URL) {
        do {
            let doc = try VideoProject(contentsOf: url, ofType: VideoProject.typeIdentifier)
            doc.makeWindowControllers()
            doc.showWindows()
            NSDocumentController.shared.addDocument(doc)
            ProjectRegistry.shared.register(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @discardableResult
    func renameProject(at url: URL, to newName: String) -> URL? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let newURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(trimmed).\(Project.fileExtension)")
        guard newURL != url else { return url }
        guard !FileManager.default.fileExists(atPath: newURL.path) else { return nil }

        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            if let doc = activeProject, doc.fileURL == url {
                doc.fileURL = newURL
            }
            ProjectRegistry.shared.updateURL(from: url, to: newURL)
            return newURL
        } catch {
            return nil
        }
    }

    func openProjectFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: Project.fileExtension)!]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Open Project"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            AppState.shared.openProject(at: url)
        }
    }

}
