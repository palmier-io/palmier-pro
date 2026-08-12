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
        let project = VideoProject()
        let editorWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let controller = NSWindowController(window: editorWindow)
        project.addWindowController(controller)
        HomeWindowController.shared.showWindow(nil)
        defer { cleanUp(project) }

        AppState.shared.activateProject(project)

        #expect(HomeWindowController.shared.window?.isVisible == true)
        #expect(!editorWindow.isVisible)

        AppState.shared.showEditor(for: project)

        #expect(editorWindow.isVisible)
        #expect(HomeWindowController.shared.window?.isVisible == false)
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
