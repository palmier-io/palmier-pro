import AppKit
import Foundation
import Synchronization
import Testing
@testable import CompositorPro

private struct NativeSaveProbe {
    var starts = 0
    var failNextWrite = false
}

private final class SaveAdmissionProject: VideoProject {
    nonisolated let nativeSaveProbe = Mutex(NativeSaveProbe())

    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for operation: NSDocument.SaveOperationType) -> Bool {
        nativeSaveProbe.withLock { $0.starts += 1 }
        return true
    }

    override func write(to url: URL, ofType typeName: String) throws {
        let shouldFail = nativeSaveProbe.withLock { probe in
            let shouldFail = probe.failNextWrite
            probe.failNextWrite = false
            return shouldFail
        }
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
        try super.write(to: url, ofType: typeName)
    }
}

@Suite("Native save admission", .serialized)
@MainActor
struct VideoProjectSaveAdmissionTests {
    @Test(.timeLimit(.minutes(1)))
    func nativeSaveStartsAfterAdmittedMutationPublishes() async throws {
        try await withPackageTestFixture { fixture in
            let document = SaveAdmissionProject(registry: fixture.registry)
            document.fileURL = fixture.package
            document.fileType = VideoProject.typeIdentifier
            let coordinator = document.editorViewModel.projectPackageCoordinator
            let admitted = PackageTestSignal()
            let release = PackageTestSignal()
            let mutation = coordinator.startMutation { _ in
                admitted.signal()
                await release.wait()
                document.editorViewModel.timeline.name = "Admitted edit"
            } onFailure: { Issue.record($0) }
            await admitted.wait()
            let saved = PackageTestSignal()
            var replies: [Bool] = []

            document.save(to: fixture.package, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                replies.append(error == nil)
                saved.signal()
            }

            #expect(document.nativeSaveProbe.withLock { $0.starts } == 0)
            #expect(replies.isEmpty)
            release.signal()
            await saved.wait()
            await mutation.value

            #expect(replies == [true])
            #expect(document.nativeSaveProbe.withLock { $0.starts } > 0)
            let persisted = try await fixture.readPackage()
            #expect(persisted.projectFile.timelines.first?.name == "Admitted edit")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func failedNativeSaveReleasesQueuedSaveAndMutation() async throws {
        try await withPackageTestFixture { fixture in
            let document = SaveAdmissionProject(registry: fixture.registry)
            document.fileURL = fixture.package
            document.fileType = VideoProject.typeIdentifier
            document.editorViewModel.timeline.name = "Before queued mutation"
            document.nativeSaveProbe.withLock { $0.failNextWrite = true }
            let coordinator = document.editorViewModel.projectPackageCoordinator
            let failed = PackageTestSignal()
            let saved = PackageTestSignal()
            var events: [String] = []
            var replies: [Bool] = []

            document.save(to: fixture.package, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                replies.append(error == nil)
                events.append("failed")
                failed.signal()
            }
            document.save(to: fixture.package, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                replies.append(error == nil)
                events.append("saved")
                saved.signal()
            }
            let mutation = coordinator.startMutation { _ in
                events.append("mutation")
                document.editorViewModel.timeline.name = "After saves"
            } onFailure: { Issue.record($0) }

            await failed.wait()
            await saved.wait()
            await mutation.value

            #expect(replies == [false, true])
            #expect(events == ["failed", "saved", "mutation"])
            await coordinator.waitUntilIdle()
            #expect(document.editorViewModel.timeline.name == "After saves")
            let persisted = try await fixture.readPackage()
            #expect(persisted.projectFile.timelines.first?.name == "Before queued mutation")
        }
    }
}
