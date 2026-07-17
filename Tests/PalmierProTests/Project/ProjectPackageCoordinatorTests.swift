import AppKit
import Testing
@testable import PalmierPro

@MainActor
private final class DocumentCloseProbe: NSObject {
    private(set) var result: Bool?

    @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        result = shouldClose
    }
}

@Suite("Project package coordination", .serialized)
@MainActor
struct ProjectPackageCoordinatorTests {
    @Test func queuedMutationRunsBeforeSaveCompletionReturns() async throws {
        let coordinator = ProjectPackageCoordinator()
        coordinator.saveStarted()
        coordinator.saveStarted()
        var enteredCoordinator = false
        var mutationRan = false
        let mutation = Task {
            enteredCoordinator = true
            try await coordinator.performMutation { mutationRan = true }
        }
        while !enteredCoordinator { await Task.yield() }
        #expect(!mutationRan)

        coordinator.saveFinished(success: false)
        #expect(!mutationRan)
        coordinator.saveFinished(success: true)
        #expect(mutationRan)
        try await mutation.value
    }

    @Test func failedPreexistingSaveCancelsQueueWithoutReopening() async {
        let coordinator = ProjectPackageCoordinator()
        coordinator.saveStarted()
        var closingStarted = false
        let closing = Task {
            closingStarted = true
            await coordinator.beginClosing()
        }
        while !closingStarted { await Task.yield() }

        var entered = false
        let mutation = Task {
            entered = true
            try await coordinator.performMutation {}
        }
        while !entered { await Task.yield() }

        coordinator.saveFinished(success: false)
        await closing.value
        await #expect(throws: CancellationError.self) { try await mutation.value }
        #expect(throws: CancellationError.self) { try coordinator.beginMutation() }
    }

    @Test func queuedMediaCommitUsesRebasedProjectURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coordinator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldURL = root.appendingPathComponent("Old.palmier", isDirectory: true)
        let newURL = root.appendingPathComponent("New.palmier", isDirectory: true)

        let document = VideoProject()
        document.fileURL = oldURL
        let editor = document.editorViewModel
        editor.projectURL = oldURL

        editor.projectPackageCoordinator.saveStarted()
        let stagedURL = try FileIO.stageData(Data("video".utf8), pathExtension: "mp4")
        let commit = Task { try await editor.commitStagedProjectMedia(stagedURL, filename: "new.mp4") }
        await Task.yield()
        document.fileURL = newURL
        editor.projectPackageCoordinator.saveFinished(success: true)

        let destination = try await commit.value
        #expect(destination == newURL.appendingPathComponent("media/new.mp4"))
    }

    @Test func nativeCloseWaitsForAcceptedMutationAndRejectsLateWork() async throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-close-\(UUID().uuidString).palmier", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let document = VideoProject()
        document.fileURL = package
        document.fileType = VideoProject.typeIdentifier
        let coordinator = document.editorViewModel.projectPackageCoordinator
        try coordinator.beginMutation()

        let probe = DocumentCloseProbe()
        document.canClose(
            withDelegate: probe,
            shouldClose: #selector(DocumentCloseProbe.document(_:shouldClose:contextInfo:)),
            contextInfo: nil
        )
        await Task.yield()
        #expect(probe.result == nil)

        coordinator.endMutation()
        while probe.result == nil { await Task.yield() }
        #expect(probe.result == true)
        #expect(throws: CancellationError.self) { try coordinator.beginMutation() }
        try coordinator.beginMutation(allowDuringClosing: true)
        coordinator.endMutation()
    }
}
