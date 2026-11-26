import AppKit
import Foundation
import Testing
@testable import CompositorPro

@MainActor
private final class CloseOwnerDocument: VideoProject {
    let saveEntered = PackageTestSignal()
    let releaseSave = PackageTestSignal()
    let delayedSaveFinished = PackageTestSignal()
    let closeFinished = PackageTestSignal()
    var cancelFirstSave = false
    private var pauseFirstSave = true

    override func saveBeforeClosing(using lease: ProjectPackageCoordinator.CloseLease) async throws {
        if pauseFirstSave {
            pauseFirstSave = false
            defer { delayedSaveFinished.signal() }
            saveEntered.signal()
            await releaseSave.wait()
            if cancelFirstSave { throw CancellationError() }
            try await super.saveBeforeClosing(using: lease)
        } else {
            try await super.saveBeforeClosing(using: lease)
        }
    }

    override func closeAfterSaving() async throws {
        defer { closeFinished.signal() }
        try await super.closeAfterSaving()
    }
}

@MainActor
private final class CloseOwnerCallback: NSObject {
    let completed = PackageTestSignal()
    private(set) var calls = 0
    private(set) var result: Bool?

    @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        calls += 1
        result = shouldClose
        completed.signal()
    }

    func requestClose(_ document: VideoProject) {
        document.canClose(withDelegate: self,
            shouldClose: #selector(CloseOwnerCallback.document(_:shouldClose:contextInfo:)), contextInfo: nil)
    }
}

@Suite("Native project close ownership", .serialized)
@MainActor
struct ProjectCloseOwnerDocumentTests {
    @Test func coalescedNativeCancellationKeepsQuitOwnerAndCompletesEveryCallbackOnce() async throws {
        try await withPackageTestFixture { fixture in
            let document = configure(fixture)
            document.cancelFirstSave = true
            defer { document.releaseSave.signal() }
            try await savePackageTestDocument(document)
            let original = try await fixture.readPackage()
            let undo = UndoManager()
            document.editorViewModel.undo.attach(undo)
            let coordinator = document.editorViewModel.projectPackageCoordinator
            let quit = try #require(document.beginClosing())
            let first = CloseOwnerCallback()
            let second = CloseOwnerCallback()
            first.requestClose(document)
            second.requestClose(document)
            await document.saveEntered.wait()
            document.releaseSave.signal()
            await first.completed.wait()
            await second.completed.wait()
            #expect(first.result == false)
            #expect(second.result == false)
            #expect(first.calls == 1)
            #expect(second.calls == 1)
            #expect(coordinator.isClosing)
            #expect(!coordinator.isClosed)
            #expect(!undo.canUndo)
            try coordinator.validate(quit)
            #expect(throws: CancellationError.self) { try coordinator.admitIntent() }
            #expect(try await fixture.readPackage().projectFile.timelines == original.projectFile.timelines)
            coordinator.cancelClosing(quit)
            #expect(!coordinator.isClosing)
            await coordinator.waitUntilIdle()
        }
    }

    @Test func toolCloseCompletesPendingNativeCallbacksAndStaleSaveCannotCompleteThemAgain() async throws {
        try await withPackageTestFixture { fixture in
            let document = configure(fixture)
            try await savePackageTestDocument(document)
            NSDocumentController.shared.addDocument(document)
            defer {
                document.releaseSave.signal()
                NSDocumentController.shared.removeDocument(document)
            }
            let first = CloseOwnerCallback()
            let second = CloseOwnerCallback()
            first.requestClose(document)
            second.requestClose(document)
            await document.saveEntered.wait()
            try await document.closeAfterSaving()
            await first.completed.wait()
            await second.completed.wait()
            #expect(first.result == true)
            #expect(second.result == true)
            document.releaseSave.signal()
            await document.delayedSaveFinished.wait()
            #expect(first.calls == 1)
            #expect(second.calls == 1)
            #expect(document.editorViewModel.projectPackageCoordinator.isClosed)
            #expect(!NSDocumentController.shared.documents.contains { $0 === document })
            try await document.closeAfterSaving()
            #expect(first.calls == 1)
        }
    }

    @Test func directCloseReservesBeforeSchedulingAndRepeatedCloseDoesNotLeakOwner() async throws {
        try await withPackageTestFixture { fixture in
            let document = configure(fixture)
            try await savePackageTestDocument(document)
            NSDocumentController.shared.addDocument(document)
            defer {
                document.releaseSave.signal()
                NSDocumentController.shared.removeDocument(document)
            }
            document.close()
            document.close()
            let coordinator = document.editorViewModel.projectPackageCoordinator
            #expect(coordinator.isClosing)
            #expect(throws: CancellationError.self) { try coordinator.admitIntent() }
            await document.saveEntered.wait()
            document.releaseSave.signal()
            await document.closeFinished.wait()
            #expect(coordinator.isClosed)
            #expect(coordinator.beginClosing() == nil)
        }
    }

    @Test func missingSelectorOrCallbackTargetDoesNotReserveClose() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let callback = CloseOwnerCallback()
            document.canClose(withDelegate: callback, shouldClose: nil, contextInfo: nil)
            document.canClose(withDelegate: NSObject(),
                shouldClose: NSSelectorFromString("missingCloseCallback:shouldClose:contextInfo:"), contextInfo: nil)
            #expect(!document.editorViewModel.projectPackageCoordinator.isClosing)
            #expect(callback.calls == 0)
            try await document.editorViewModel.projectPackageCoordinator.withMutation { _ in }
        }
    }

    @Test func abortOpeningDrainsEvenWhenInitiatingTaskWasAlreadyCancelled() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            try await savePackageTestDocument(document)
            NSDocumentController.shared.addDocument(document)
            defer { NSDocumentController.shared.removeDocument(document) }
            let abort = Task { await document.abortOpening() }
            abort.cancel()
            await abort.value
            #expect(document.editorViewModel.projectPackageCoordinator.isClosed)
            #expect(!NSDocumentController.shared.documents.contains { $0 === document })
            #expect(try await fixture.readPackage().projectFile.timelines.count == 1)
        }
    }

    @Test func quitLeaseClosesImmediatelyAndClearsDocumentControllerRegistry() async throws {
        try await withPackageTestFixture { fixture in
            let document = configure(fixture)
            try await savePackageTestDocument(document)
            NSDocumentController.shared.addDocument(document)
            defer {
                document.releaseSave.signal()
                NSDocumentController.shared.removeDocument(document)
            }
            let lease = try #require(document.beginClosing())
            Task {
                await document.saveEntered.wait()
                document.releaseSave.signal()
            }
            try await document.saveBeforeClosing(using: lease)
            let coordinator = document.editorViewModel.projectPackageCoordinator
            try await coordinator.waitUntilIdle(for: lease)
            #expect(coordinator.canFinishClosing)
            try document.closeImmediately(using: lease)
            #expect(coordinator.isClosed)
            #expect(!NSDocumentController.shared.documents.contains { $0 === document })
        }
    }

    private func configure(_ fixture: PackageTestFixture) -> CloseOwnerDocument {
        let document = CloseOwnerDocument(registry: fixture.registry)
        document.fileURL = fixture.package
        document.fileType = VideoProject.typeIdentifier
        document.editorViewModel.projectURL = fixture.package
        return document
    }
}
