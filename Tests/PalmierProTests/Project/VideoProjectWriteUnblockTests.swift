import AppKit
import Foundation
import Testing
@testable import PalmierPro

private class UnblockCountingProject: VideoProject {
    nonisolated(unsafe) private(set) var unblockCount = 0
    override func unblockUserInteraction() { unblockCount += 1 }
}

private final class UnblockOrderingProject: UnblockCountingProject {
    nonisolated(unsafe) private(set) var unblockCountAtWriteEntry: Int?

    override func write(to url: URL, ofType typeName: String) throws {
        unblockCountAtWriteEntry = unblockCount
        try super.write(to: url, ofType: typeName)
    }
}

private final class DelayedSafeWriteProject: VideoProject {
    nonisolated(unsafe) var delaySafeWrites = false
    let safeWriteEntered = DispatchSemaphore(value: 0)
    let allowSafeWrite = DispatchSemaphore(value: 0)

    override func writeSafely(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType
    ) throws {
        if delaySafeWrites {
            unblockUserInteraction()
            safeWriteEntered.signal()
            allowSafeWrite.wait()
        }
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
    }
}

@MainActor
private func save(_ document: VideoProject, to url: URL) async -> Error? {
    await withCheckedContinuation { continuation in
        document.save(
            to: url,
            ofType: VideoProject.typeIdentifier,
            for: .saveOperation
        ) { error in
            continuation.resume(returning: error)
        }
    }
}

private func wait(for semaphore: DispatchSemaphore) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            semaphore.wait()
            continuation.resume()
        }
    }
}

/// With `canAsynchronouslyWrite` enabled, AppKit parks the main thread in
/// `_waitForUserInteractionUnblocking` until `write()` calls `unblockUserInteraction()`.
/// A throw that skips the unblock freezes the app permanently (issue #402).
@Suite("VideoProject write() main-thread unblocking", .serialized)
struct VideoProjectWriteUnblockTests {

    private func temporaryBundleURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vp-unblock-\(UUID().uuidString).palmier", isDirectory: true)
    }

    @Test func offMainWriteWithoutSnapshotThrowsButStillUnblocks() async {
        let doc = await MainActor.run { UnblockCountingProject() }
        let url = temporaryBundleURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // The racing-save shape: a second save's write() lands off-main after the
        // first write() consumed the shared snapshot.
        await Task.detached {
            #expect(throws: CocoaError.self) {
                try doc.write(to: url, ofType: VideoProject.typeIdentifier)
            }
        }.value

        #expect(doc.unblockCount == 1)
    }

    @Test func successfulWriteUnblocksExactlyOnce() async throws {
        let doc = await MainActor.run {
            let doc = UnblockCountingProject()
            doc.editorViewModel.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack()])
            return doc
        }
        let url = temporaryBundleURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try await MainActor.run {
            try doc.write(to: url, ofType: VideoProject.typeIdentifier)
        }

        #expect(doc.unblockCount == 1)
    }

    @Test func safeWriteUnblocksBeforeEnteringWrite() async throws {
        let doc = await MainActor.run {
            let doc = UnblockOrderingProject()
            doc.editorViewModel.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack()])
            return doc
        }
        let url = temporaryBundleURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try await MainActor.run {
            try doc.writeSafely(
                to: url,
                ofType: VideoProject.typeIdentifier,
                for: .saveOperation
            )
        }

        #expect(doc.unblockCountAtWriteEntry == 1)
    }

    @Test func overlappingSavesPreserveLatestSnapshot() async throws {
        let url = temporaryBundleURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = await MainActor.run {
            let doc = DelayedSafeWriteProject()
            doc.fileURL = url
            doc.fileType = VideoProject.typeIdentifier
            doc.editorViewModel.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack()])
            return doc
        }
        #expect(await save(doc, to: url) == nil)

        await MainActor.run {
            doc.editorViewModel.timeline.name = "First save"
            doc.updateChangeCount(.changeDone)
            doc.delaySafeWrites = true
        }
        let firstSave = Task { @MainActor in await save(doc, to: url) }
        await wait(for: doc.safeWriteEntered)

        await MainActor.run {
            doc.editorViewModel.timeline.name = "Second save"
            doc.updateChangeCount(.changeDone)
        }
        let release = doc.allowSafeWrite
        let releaseWrites = Task.detached {
            try? await Task.sleep(for: .milliseconds(100))
            release.signal()
            release.signal()
        }
        let secondSave = Task { @MainActor in await save(doc, to: url) }

        let firstError = await firstSave.value
        let secondError = await secondSave.value
        await releaseWrites.value
        #expect(firstError == nil)
        #expect(secondError == nil)

        let saved = try VideoProject.readProjectPackage(at: url)
        #expect(saved.projectFile.timelines.first?.name == "Second save")
    }
}
