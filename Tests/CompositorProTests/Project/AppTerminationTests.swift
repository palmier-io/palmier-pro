import AppKit
import Testing
@testable import CompositorPro

@Suite("App termination persistence", .serialized)
@MainActor
struct AppTerminationTests {
    @Test func waitsForAdmittedWorkThenSavesBeforeReplyingOnce() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            try await savePackageTestDocument(document)
            let coordinator = document.editorViewModel.projectPackageCoordinator
            let entered = PackageTestSignal()
            let release = PackageTestSignal()
            let finished = PackageTestSignal()
            let pending = Task { @MainActor in
                try await coordinator.withIntent { _ in
                    entered.signal()
                    await release.wait()
                    document.editorViewModel.timeline.name = "Latest admitted edit"
                }
            }
            await entered.wait()
            let delegate = AppDelegate()
            var replies: [Bool] = []
            var servicesPrepared = false
            var closed = false
            delegate.startTermination(projects: [document], prepareServices: { _ in
                servicesPrepared = true
            }, didClose: { closed = true }, onError: { Issue.record("Unexpected quit failure: \($0)") }, sendReply: {
                replies.append($0)
                finished.signal()
            })
            #expect(coordinator.isClosing)
            #expect(replies.isEmpty)
            #expect(!servicesPrepared)
            #expect(!closed)
            #expect(throws: CancellationError.self) { try coordinator.admitIntent() }
            delegate.startTermination(projects: [document], prepareServices: { _ in }, didClose: {}, onError: { _ in }, sendReply: { _ in
                Issue.record("Duplicate termination request replied")
            })
            release.signal()
            try await pending.value
            await finished.wait()
            #expect(replies == [true])
            #expect(servicesPrepared && closed && coordinator.isClosed)
            let persisted = try await fixture.readPackage()
            #expect(persisted.projectFile.timelines.first?.name == "Latest admitted edit")
        }
    }

    @Test func failedFinalSaveRefusesQuitAndAllowsRetry() async throws {
        try await withPackageTestFixture { fixture in
            let document = fixture.document()
            try await savePackageTestDocument(document)
            let original = try await fixture.readPackage()
            document.editorViewModel.mediaManifest.entries = [
                .init(id: "invalid", name: "Invalid", type: .video, source: .external(absolutePath: "/tmp/invalid"), duration: .nan),
            ]
            let delegate = AppDelegate()
            let failed = PackageTestSignal()
            var replies: [Bool] = []
            var errors = 0
            delegate.startTermination(projects: [document], prepareServices: { _ in Issue.record("Services stopped after save failure") },
                didClose: { Issue.record("Closed after save failure") }, onError: { _ in errors += 1 }, sendReply: {
                    replies.append($0)
                    failed.signal()
                })
            await failed.wait()
            #expect(replies == [false] && errors == 1)
            #expect(!delegate.isTerminating)
            #expect(!document.editorViewModel.projectPackageCoordinator.isClosing)
            let retained = try await fixture.readPackage()
            #expect(retained.projectFile.timelines == original.projectFile.timelines)
            #expect(retained.manifest == original.manifest)
            document.editorViewModel.mediaManifest.entries = []
            let retried = PackageTestSignal()
            delegate.startTermination(projects: [document], prepareServices: { _ in }, didClose: {}, onError: { Issue.record("Retry failed: \($0)") }, sendReply: {
                replies.append($0)
                retried.signal()
            })
            await retried.wait()
            #expect(replies == [false, true])
        }
    }
}
