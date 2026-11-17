import AppKit
import Testing
@testable import CompositorPro

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

    @Test(.timeLimit(.minutes(1)))
    func restorationBringsTheCurrentWindowAboveOtherWindows() async throws {
        let application = NSApplication.shared
        let (project, editorWindow) = makeProjectWindow()
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        defer { otherWindow.orderOut(nil); cleanUp(project) }
        try await WindowEventWaiter().wait(for: NSWindow.didBecomeMainNotification, from: editorWindow) {
            application.activate(ignoringOtherApps: true)
            editorWindow.makeKeyAndOrderFront(nil)
            editorWindow.makeMain()
        }
        otherWindow.orderFront(nil)
        try #require(application.mainWindow === editorWindow)
        try #require(application.orderedWindows.first { $0 === editorWindow || $0 === otherWindow } === otherWindow)

        AppState.shared.restoreWindowForActivation(restoringMinimizedWindows: false)

        #expect(application.orderedWindows.first { $0 === editorWindow || $0 === otherWindow } === editorWindow)
    }

    @Test(.timeLimit(.minutes(1)))
    func restorationRestoresTheMinimizedProjectWithoutSwitchingToHome() async throws {
        _ = NSApplication.shared
        let (project, editorWindow) = makeProjectWindow()
        defer { cleanUp(project) }
        AppState.shared.activateProject(project)
        editorWindow.makeKeyAndOrderFront(nil)
        HomeWindowController.shared.window?.orderOut(nil)
        try await WindowEventWaiter().wait(for: NSWindow.didMiniaturizeNotification, from: editorWindow) {
            editorWindow.miniaturize(nil)
        }
        try #require(editorWindow.isMiniaturized)

        try await WindowEventWaiter().wait(for: NSWindow.didDeminiaturizeNotification, from: editorWindow) {
            AppState.shared.restoreWindowForActivation(restoringMinimizedWindows: true)
        }

        #expect(!editorWindow.isMiniaturized)
        #expect(editorWindow.isVisible)
        #expect(AppState.shared.activeProject === project)
        #expect(HomeWindowController.shared.window?.isVisible == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func restorationPreservesTheFocusedAuxiliaryWindow() async throws {
        let application = NSApplication.shared
        let (project, editorWindow) = makeProjectWindow()
        let auxiliaryWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                                       styleMask: [.titled], backing: .buffered, defer: false)
        defer { auxiliaryWindow.orderOut(nil); cleanUp(project) }
        AppState.shared.activateProject(project)
        editorWindow.makeKeyAndOrderFront(nil)
        try await WindowEventWaiter().wait(for: NSWindow.didBecomeKeyNotification, from: auxiliaryWindow) {
            application.activate(ignoringOtherApps: true)
            auxiliaryWindow.makeKeyAndOrderFront(nil)
        }
        try #require(application.keyWindow === auxiliaryWindow)

        AppState.shared.restoreWindowForActivation(restoringMinimizedWindows: false)

        #expect(application.keyWindow === auxiliaryWindow)
        #expect(AppState.shared.activeProject === project)
    }

    @Test func restorationDoesNotPresentAnUnshownEditorOverHome() {
        _ = NSApplication.shared
        let (project, editorWindow) = makeProjectWindow()
        defer { cleanUp(project) }
        AppState.shared.activateProject(project)
        HomeWindowController.shared.showWindow(nil)

        AppState.shared.restoreWindowForActivation(restoringMinimizedWindows: false)

        #expect(!editorWindow.isVisible)
        #expect(HomeWindowController.shared.window?.isVisible == true)
    }

    private func makeProjectWindow() -> (VideoProject, NSWindow) {
        let project = VideoProject()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .miniaturizable],
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

@MainActor
private final class WindowEventWaiter {
    private var observer: NSObjectProtocol?
    private var continuation: CheckedContinuation<Void, any Error>?

    func wait(for name: Notification.Name, from window: NSWindow, action: () -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else {
                    finish(error: CancellationError())
                    return
                }
                observer = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finish(error: nil) }
                }
                action()
            }
        } onCancel: {
            Task { @MainActor in self.finish(error: CancellationError()) }
        }
    }

    private func finish(error: (any Error)?) {
        guard let continuation else { return }
        self.continuation = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
}
