import Foundation
import Testing
@testable import PalmierPro

private final class UnblockCountingProject: VideoProject {
    nonisolated(unsafe) private(set) var unblockCount = 0
    override func unblockUserInteraction() { unblockCount += 1 }
}

/// With `canAsynchronouslyWrite` enabled, AppKit parks the main thread in
/// `_waitForUserInteractionUnblocking` until `write()` calls `unblockUserInteraction()`.
/// A throw that skips the unblock freezes the app permanently (issue #402).
@Suite("VideoProject write() main-thread unblocking")
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
}
