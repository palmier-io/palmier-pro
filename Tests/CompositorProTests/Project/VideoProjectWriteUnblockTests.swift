import AppKit
import Foundation
import Synchronization
import Testing
@testable import CompositorPro

private struct WriteProbeState {
    var unblockCount = 0
    var unblockCountAtWriteEntry: Int?
}

private class UnblockCountingProject: VideoProject {
    nonisolated let writeProbe = Mutex(WriteProbeState())

    override func unblockUserInteraction() {
        writeProbe.withLock { $0.unblockCount += 1 }
        super.unblockUserInteraction()
    }

    override func write(to url: URL, ofType typeName: String) throws {
        writeProbe.withLock { $0.unblockCountAtWriteEntry = $0.unblockCount }
        try super.write(to: url, ofType: typeName)
    }
}

private final class SafeWriteGate: Sendable {
    let entered: PackageTestSignal
    let permit = DispatchSemaphore(value: 0)

    @MainActor init() { entered = PackageTestSignal() }
}

private final class GatedSafeWriteProject: UnblockCountingProject {
    nonisolated let nextWriteGate = Mutex<SafeWriteGate?>(nil)

    override func writeSafely(to url: URL, ofType typeName: String, for operation: NSDocument.SaveOperationType) throws {
        #expect(!Thread.isMainThread)
        guard !Thread.isMainThread else { throw CocoaError(.fileWriteUnknown) }
        let gate = nextWriteGate.withLock { value in
            let gate = value
            value = nil
            return gate
        }
        if let gate {
            unblockUserInteraction()
            Task { @MainActor in gate.entered.signal() }
            gate.permit.wait()
        }
        try super.writeSafely(to: url, ofType: typeName, for: operation)
    }
}

@Suite("VideoProject write unblocking", .serialized)
@MainActor
struct VideoProjectWriteUnblockTests {
    @Test func offMainWriteWithoutContextThrowsButStillUnblocks() async throws {
        try await withPackageTestFixture { fixture in
            let document = UnblockCountingProject()
            let package = fixture.package
            let typeIdentifier = VideoProject.typeIdentifier
            _ = await Task.detached {
                #expect(throws: CocoaError.self) { try document.write(to: package, ofType: typeIdentifier) }
            }.value
            #expect(document.writeProbe.withLock { $0.unblockCount } == 1)
            let packageExists = try await fixture.exists(package)
            #expect(!packageExists)
        }
    }

    @Test func mainThreadDirectWriteIsRejectedWithoutTouchingPackage() async throws {
        try await withPackageTestFixture { fixture in
            let document = UnblockCountingProject()
            #expect(throws: CocoaError.self) { try document.write(to: fixture.package, ofType: VideoProject.typeIdentifier) }
            #expect(document.writeProbe.withLock { $0.unblockCount } == 1)
            let packageExists = try await fixture.exists(fixture.package)
            #expect(!packageExists)
        }
    }

    @Test func nativeSafeSaveUnblocksBeforeWriteEntry() async throws {
        try await withPackageTestFixture { fixture in
            let document = UnblockCountingProject()
            document.fileURL = fixture.package
            document.fileType = VideoProject.typeIdentifier
            try await savePackageTestDocument(document)
            #expect(try #require(document.writeProbe.withLock { $0.unblockCountAtWriteEntry }) >= 1)
            let saved = try await fixture.readPackage()
            #expect(saved.projectFile.timelines == document.editorViewModel.timelines)
        }
    }

    @Test func overlappingNativeSavesPreserveLatestSnapshot() async throws {
        try await withPackageTestFixture { fixture in
            let document = GatedSafeWriteProject()
            document.fileURL = fixture.package
            document.fileType = VideoProject.typeIdentifier
            try await savePackageTestDocument(document)
            let gate = SafeWriteGate()
            document.nextWriteGate.withLock { $0 = gate }
            document.editorViewModel.timeline.name = "First save"
            document.updateChangeCount(.changeDone)
            let firstSave = Task { try await savePackageTestDocument(document) }
            await gate.entered.wait()
            document.editorViewModel.timeline.name = "Second save"
            document.updateChangeCount(.changeDone)
            let secondFinished = PackageTestSignal()
            var secondError: Error?
            document.save(to: fixture.package, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                secondError = error
                secondFinished.signal()
            }
            gate.permit.signal()
            try await firstSave.value
            await secondFinished.wait()
            #expect(secondError == nil)
            let saved = try await fixture.readPackage()
            #expect(saved.projectFile.timelines.first?.name == "Second save")
        }
    }
}
