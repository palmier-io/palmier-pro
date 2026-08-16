import AppKit
import Testing
@testable import PalmierPro

@Suite("Project window presentation", .serialized)
@MainActor
struct ProjectWindowPresentationTests {
    @Test func makingWindowControllersDoesNotPresentProject() {
        _ = NSApplication.shared
        let project = VideoProject()
        HomeWindowController.shared.showWindow(nil)
        defer { cleanUp(project) }

        project.makeWindowControllers()

        #expect(!project.windowControllers.isEmpty)
        #expect(project.windowControllers.allSatisfy { $0.window?.isVisible == false })
        #expect(AppState.shared.activeProject !== project)
        #expect(HomeWindowController.shared.window?.isVisible == true)
    }

    @Test func activationKeepsHomeVisibleUntilEditorIsPresented() {
        _ = NSApplication.shared
        let (project, editorWindow) = makeProjectWindow()
        HomeWindowController.shared.showWindow(nil)
        defer { cleanUp(project) }

        AppState.shared.activateProject(project)

        #expect(HomeWindowController.shared.window?.isVisible == true)
        #expect(!editorWindow.isVisible)

        AppState.shared.showEditor(for: project)

        #expect(editorWindow.isVisible)
        #expect(HomeWindowController.shared.window?.isVisible == false)
    }

    @Test func keyProjectWindowHidesHomeForDocumentControllerPresentation() {
        _ = NSApplication.shared
        let (project, editorWindow) = makeProjectWindow()
        HomeWindowController.shared.showWindow(nil)
        editorWindow.orderFront(nil)
        defer { cleanUp(project) }

        AppState.shared.projectWindowDidBecomeKey(project)

        #expect(AppState.shared.activeProject === project)
        #expect(editorWindow.isVisible)
        #expect(HomeWindowController.shared.window?.isVisible == false)
    }

    @Test func closingEditorWindowKeepsProjectSessionLoaded() async throws {
        _ = NSApplication.shared
        let project = VideoProject()
        project.prepareSession()
        project.makeWindowControllers()
        NSDocumentController.shared.addDocument(project)
        defer {
            NSDocumentController.shared.removeDocument(project)
            cleanUp(project)
        }

        AppState.shared.showEditor(for: project)
        let controller = try #require(project.windowControllers.first as? EditorWindowController)
        let window = try #require(controller.window)

        window.performClose(nil)
        await waitForMainQueue()

        #expect(!window.isVisible)
        #expect(NSDocumentController.shared.documents.contains { $0 === project })
        #expect(project.isSessionPrepared)
    }

    @Test func closingVisibleProjectDoesNotPresentBackgroundSession() {
        _ = NSApplication.shared
        let background = VideoProject()
        background.prepareSession()
        NSDocumentController.shared.addDocument(background)
        let (visible, _) = makeProjectWindow()
        NSDocumentController.shared.addDocument(visible)
        defer {
            NSDocumentController.shared.removeDocument(background)
            NSDocumentController.shared.removeDocument(visible)
            cleanUp(background)
            cleanUp(visible)
        }

        AppState.shared.showEditor(for: visible)
        NSDocumentController.shared.removeDocument(visible)
        AppState.shared.projectDidClose(visible)

        #expect(AppState.shared.activeProject == nil)
        #expect(background.windowControllers.isEmpty)
    }

    private func makeProjectWindow() -> (VideoProject, NSWindow) {
        let project = VideoProject()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        project.addWindowController(NSWindowController(window: window))
        return (project, window)
    }

    private func cleanUp(_ project: VideoProject) {
        if AppState.shared.activeProject === project {
            AppState.shared.showHome()
        }
        for controller in project.windowControllers {
            controller.window?.orderOut(nil)
            project.removeWindowController(controller)
        }
        HomeWindowController.shared.window?.orderOut(nil)
    }

    private func waitForMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
