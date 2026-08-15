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
}
