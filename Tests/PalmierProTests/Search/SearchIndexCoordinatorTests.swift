import Foundation
import Testing
@testable import PalmierPro

@Suite("SearchIndexCoordinator — transcript gating")
@MainActor
struct TranscriptGatingTests {
    private func asset(type: ClipType, hasAudio: Bool) -> MediaAsset {
        let a = MediaAsset(url: URL(fileURLWithPath: "/tmp/x.mov"), type: type, name: "x", duration: 5)
        a.hasAudio = hasAudio
        return a
    }

    @Test func wantsTranscriptOnlyForAudioBearingMedia() {
        #expect(SearchIndexCoordinator.wantsTranscript(asset(type: .video, hasAudio: true)))
        #expect(SearchIndexCoordinator.wantsTranscript(asset(type: .audio, hasAudio: false)))
        #expect(!SearchIndexCoordinator.wantsTranscript(asset(type: .video, hasAudio: false)))
        #expect(!SearchIndexCoordinator.wantsTranscript(asset(type: .image, hasAudio: false)))
    }

    @Test func hasCachedOnDiskFalseForUncachedFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("no-\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!TranscriptCache.hasCachedOnDisk(for: url))
    }
}
