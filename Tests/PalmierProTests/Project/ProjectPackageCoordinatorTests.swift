import AppKit
import Testing
@testable import PalmierPro

@MainActor
private final class DocumentCloseProbe: NSObject {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var result: Bool?

    @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        result = shouldClose
        continuation?.resume(returning: shouldClose)
        continuation = nil
    }

    func waitForResult() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }
}

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
        while true {
            do {
                try coordinator.beginMutation()
                coordinator.endMutation()
                await Task.yield()
            } catch is CancellationError {
                break
            }
        }
        #expect(probe.result == nil)

        coordinator.endMutation()
        #expect(await probe.waitForResult())
        #expect(throws: CancellationError.self) { try coordinator.beginMutation() }
    }
}
