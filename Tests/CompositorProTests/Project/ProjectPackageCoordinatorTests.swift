import AppKit
import Foundation
import Testing
@testable import CompositorPro

@MainActor
private final class DocumentCloseProbe: NSObject {
    let completed = PackageTestSignal()
    private(set) var result: Bool?
    private(set) var calls = 0

    @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        result = shouldClose
        calls += 1
        completed.signal()
    }
}

@Suite("Project package coordination", .serialized)
@MainActor
struct ProjectPackageCoordinatorTests {
    @Test func saveFenceWaitsForPublicationAndCleanup() async throws {
        let coordinator = ProjectPackageCoordinator()
        let admitted = PackageTestSignal()
        let finish = PackageTestSignal()
        var events: [String] = []
        let mutation = Task {
            try await coordinator.withMutation { _ in
                admitted.signal()
                await finish.wait()
                events.append("publish")
                events.append("cleanup")
            }
        }
        await admitted.wait()
        coordinator.enqueueSave { lease in
            events.append("snapshot")
            coordinator.finishSave(lease) { events.append("complete") }
        }
        #expect(events.isEmpty)
        finish.signal()
        try await mutation.value
        #expect(events == ["publish", "cleanup", "snapshot", "complete"])
    }

    @Test func fifoSavesKeepPostFenceAdmissionsUncounted() async throws {
        let coordinator = ProjectPackageCoordinator()
        var events: [String] = []
        var firstLease: ProjectPackageCoordinator.SaveLease?
        coordinator.enqueueSave { lease in firstLease = lease; events.append("first") }
        coordinator.enqueueSave { lease in
            events.append("second")
            coordinator.finishSave(lease) { events.append("secondComplete") }
        }
        let entered = PackageTestSignal()
        let mutation = Task {
            entered.signal()
            try await coordinator.withMutation { _ in events.append("mutation") }
        }
        await entered.wait()
        #expect(events == ["first"])
        coordinator.finishSave(try #require(firstLease)) { events.append("firstComplete") }
        #expect(events == ["first", "firstComplete", "second", "secondComplete"])
        try await mutation.value
        #expect(events.last == "mutation")
    }

    @Test func completionCanEnqueueAnotherSaveWithoutOverlappingItsFence() async throws {
        let coordinator = ProjectPackageCoordinator()
        var firstLease: ProjectPackageCoordinator.SaveLease?
        var secondStarted = false
        coordinator.enqueueSave { firstLease = $0 }
        coordinator.finishSave(try #require(firstLease)) {
            coordinator.enqueueSave { lease in
                secondStarted = true
                coordinator.finishSave(lease) {}
            }
            #expect(!secondStarted)
        }
        #expect(secondStarted)
        await coordinator.waitUntilIdle()
    }

    @Test func cancelledAdmissionDoesNotRunOrBlockSaveCompletion() async throws {
        let coordinator = ProjectPackageCoordinator()
        var saveLease: ProjectPackageCoordinator.SaveLease?
        coordinator.enqueueSave { saveLease = $0 }
        let entered = PackageTestSignal()
        var ran = false
        let mutation = Task {
            entered.signal()
            try await coordinator.withMutation { _ in ran = true }
        }
        await entered.wait()
        mutation.cancel()
        await #expect(throws: CancellationError.self) { try await mutation.value }
        coordinator.finishSave(try #require(saveLease)) {}
        await coordinator.waitUntilIdle()
        #expect(!ran)
    }

    @Test func ownedMutationReservesAdmissionBeforeTaskStarts() async {
        let coordinator = ProjectPackageCoordinator()
        let entered = PackageTestSignal()
        let finish = PackageTestSignal()
        var saved = false
        coordinator.startMutation { _ in
            entered.signal()
            await finish.wait()
        } onFailure: { Issue.record($0) }
        coordinator.enqueueSave { lease in
            saved = true
            coordinator.finishSave(lease) {}
        }
        #expect(!saved)
        await entered.wait()
        finish.signal()
        await coordinator.waitUntilIdle()
        #expect(saved)
    }

    @Test func preStartCancellationPublishesFailureBeforeSaveFenceOpens() async {
        let coordinator = ProjectPackageCoordinator()
        var status = "preparing"
        var savedStatus: String?
        var failures = 0
        let mutation = coordinator.startMutation { _ in
            Issue.record("Cancelled operation ran")
        } onFailure: { error in
            #expect(error is CancellationError)
            failures += 1
            status = "cancelled"
        }
        mutation.cancel()
        coordinator.enqueueSave { lease in
            savedStatus = status
            coordinator.finishSave(lease) {}
        }
        await mutation.value
        await coordinator.waitUntilIdle()
        #expect(failures == 1)
        #expect(savedStatus == "cancelled")
    }

    @Test func closingRejectsQueuedAndNewAdmissionsButDrainsGrantedWork() async throws {
        let coordinator = ProjectPackageCoordinator()
        let admitted = PackageTestSignal()
        let finish = PackageTestSignal()
        let mutation = Task {
            try await coordinator.withMutation { lease in
                admitted.signal()
                await finish.wait()
                try coordinator.validate(lease)
            }
        }
        await admitted.wait()
        coordinator.enqueueSave { lease in coordinator.finishSave(lease) {} }
        let entered = PackageTestSignal()
        let waiting = Task {
            entered.signal()
            try await coordinator.withMutation { _ in Issue.record("Late admission ran") }
        }
        await entered.wait()
        let close = try #require(coordinator.beginClosing())
        await #expect(throws: CancellationError.self) { try await waiting.value }
        await #expect(throws: CancellationError.self) { try await coordinator.withMutation { _ in } }
        #expect(!coordinator.canFinishClosing)
        finish.signal()
        try await mutation.value
        await coordinator.waitUntilIdle()
        #expect(coordinator.canFinishClosing)
        coordinator.cancelClosing(close)
        try await coordinator.withMutation { _ in }
    }

    @Test func queuedInstallationResolvesDestinationAfterRebase() async throws {
        try await withPackageTestFixture { fixture in
            let editor = EditorViewModel()
            editor.projectURL = fixture.package
            let rebased = fixture.root.appendingPathComponent("Rebased.palmier", isDirectory: true)
            let stage = try await fixture.stage()
            let coordinator = editor.projectPackageCoordinator
            var saveLease: ProjectPackageCoordinator.SaveLease?
            coordinator.enqueueSave { saveLease = $0 }
            let entered = PackageTestSignal()
            let mutation = Task {
                entered.signal()
                return try await coordinator.withMutation { lease in
                    try await editor.commitStagedProjectMedia(stage, filename: "result.mp4", lease: lease) { destination in
                        editor.importMediaAsset(MediaAsset(url: destination, type: .video, name: "Result"))
                    }
                }
            }
            await entered.wait()
            editor.rebaseProjectURL(from: fixture.package, to: rebased)
            coordinator.finishSave(try #require(saveLease)) {}
            let destination = try await mutation.value
            #expect(destination == rebased.appendingPathComponent("media/result.mp4"))
            #expect(try await fixture.contents(of: destination) == Data("MEDIA".utf8))
            #expect(try await !fixture.exists(fixture.package.appendingPathComponent("media/result.mp4")))
            #expect(try await !fixture.exists(stage))
        }
    }

    @Test func nativeClosePersistsGrantedMediaBeforeCompletingDelegateOnce() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            let editor = document.editorViewModel
            let coordinator = editor.projectPackageCoordinator
            let stage = try await fixture.stage()
            let admitted = PackageTestSignal()
            let finish = PackageTestSignal()
            let mutation = Task {
                try await coordinator.withMutation { lease in
                    admitted.signal()
                    await finish.wait()
                    _ = try await editor.commitStagedProjectMedia(stage, filename: "rendered.mp4", lease: lease) { destination in
                        editor.importMediaAsset(MediaAsset(id: "rendered", url: destination, type: .video, name: "Rendered"))
                    }
                }
            }
            await admitted.wait()
            let probe = DocumentCloseProbe()
            document.canClose(withDelegate: probe,
                shouldClose: #selector(DocumentCloseProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
            #expect(coordinator.isClosing)
            #expect(probe.result == nil)
            await #expect(throws: CancellationError.self) { try await coordinator.withMutation { _ in } }
            finish.signal()
            try await mutation.value
            await probe.completed.wait()
            #expect(probe.result == true)
            #expect(probe.calls == 1)
            let saved = try await fixture.readPackage()
            #expect(saved.manifest?.entries.first?.id == "rendered")
            #expect(saved.manifest?.entries.first?.source == .project(relativePath: "media/rendered.mp4"))
            #expect(try await fixture.contents(of: fixture.package.appendingPathComponent("media/rendered.mp4")) == Data("MEDIA".utf8))
        }
    }
}
