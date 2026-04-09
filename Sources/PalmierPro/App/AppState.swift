import SwiftUI

@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    private(set) var activeProject: VideoProject?

    func showHome() {
        activeProject?.windowControllers.forEach { $0.window?.orderOut(nil) }
        activeProject = nil
        HomeWindowController.shared.showWindow(nil)
    }

    func showEditor(for project: VideoProject) {
        activeProject = project
        HomeWindowController.shared.window?.orderOut(nil)
        project.showWindows()
    }

    // MARK: - Project lifecycle

    // TODO: Replace with NSDocumentController.shared.newDocument() when running as .app bundle
    func createNewProject() {
        let url = Self.nextAvailableURL()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let doc = VideoProject()
        doc.fileURL = url
        doc.fileType = VideoProject.typeIdentifier
        doc.makeWindowControllers()
        doc.showWindows()
        NSDocumentController.shared.addDocument(doc)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        doc.save(to: url, ofType: VideoProject.typeIdentifier, for: .saveOperation) { _ in }
    }

    // TODO: Replace with NSDocumentController.shared.openDocument(withContentsOf:) when running as .app bundle
    func openProject(at url: URL) {
        do {
            let doc = try VideoProject(contentsOf: url, ofType: VideoProject.typeIdentifier)
            doc.makeWindowControllers()
            doc.showWindows()
            NSDocumentController.shared.addDocument(doc)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
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
            NSDocumentController.shared.noteNewRecentDocumentURL(newURL)
            return newURL
        } catch {
            return nil
        }
    }

    private static func nextAvailableURL() -> URL {
        let base = Project.defaultProjectName
        var n = 1
        while true {
            let name = n == 1 ? "\(base).\(Project.fileExtension)" : "\(base) \(n).\(Project.fileExtension)"
            let url = Project.storageDirectory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }
}
