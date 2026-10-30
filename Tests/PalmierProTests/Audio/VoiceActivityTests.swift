import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite("VoiceActivity")
struct VoiceActivityTests {
    @Test func reportsOnlyDamagedMedia() {
        let damagedMedia = NSError(domain: AVFoundationErrorDomain, code: -11829)
        let wrappedDamage = AudioTrackReader.ReadError.readFailed(
            damagedMedia.localizedDescription,
            underlying: damagedMedia
        )

        #expect(VoiceActivity.isDamagedMedia(damagedMedia))
        #expect(VoiceActivity.isDamagedMedia(wrappedDamage))
        #expect(!VoiceActivity.isDamagedMedia(NSError(domain: AVFoundationErrorDomain, code: -11800)))
        #expect(!VoiceActivity.isDamagedMedia(CancellationError()))
    }

    @Test func cachesNoAudioAsEmptyAnalysis() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vad-no-audio-\(UUID().uuidString).mov")
        try Data().write(to: url)
        let mediaRef = "vad-no-audio-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: url)
            removeCacheEntries(for: mediaRef)
        }

        let analysis = VoiceActivity.cacheNoAudioAnalysis(for: url, mediaRef: mediaRef)

        #expect(analysis.chunkCount == 0)
        #expect(analysis.segments.isEmpty)
        #expect(VoiceActivity.cachedAnalysis(for: url, mediaRef: mediaRef)?.chunkCount == 0)
    }

    private func removeCacheEntries(for mediaRef: String) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: VoiceActivity.cache.directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("\(mediaRef)_") {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
