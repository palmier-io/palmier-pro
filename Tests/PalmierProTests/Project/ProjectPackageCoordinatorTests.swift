import Foundation
import Testing
@testable import PalmierPro

@Suite("Project package coordination", .serialized)
@MainActor
struct ProjectPackageCoordinatorTests {
    @Test func queuedMutationRunsBeforeSaveCompletionReturns() async throws {
        let coordinator = ProjectPackageCoordinator()
        coordinator.saveStarted()
        var enteredCoordinator = false
        var mutationRan = false
        let mutation = Task {
            enteredCoordinator = true
            try await coordinator.performMutation { mutationRan = true }
        }
        while !enteredCoordinator { await Task.yield() }
        #expect(!mutationRan)

        coordinator.saveFinished()
        #expect(mutationRan)
        try await mutation.value
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
        editor.projectPackageCoordinator.saveFinished()

        let destination = try await commit.value
        #expect(destination == newURL.appendingPathComponent("media/new.mp4"))
    }

    @Test func closeWaitsForAcceptedMutationAndRejectsLateWork() async throws {
        let coordinator = ProjectPackageCoordinator()
        try coordinator.beginMutation()
        var didClose = false
        let closing = Task {
            await coordinator.beginClosing()
            didClose = true
        }
        await Task.yield()
        #expect(!didClose)

        coordinator.endMutation()
        await closing.value
        #expect(throws: CancellationError.self) { try coordinator.beginMutation() }
    }
}
