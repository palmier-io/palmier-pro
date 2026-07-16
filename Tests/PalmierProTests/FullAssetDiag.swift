import XCTest
@testable import PalmierPro

final class FullAssetDiagTests: XCTestCase {
    func testFullAssetWindow() async throws {
        guard let path = ProcessInfo.processInfo.environment["PALMIER_FULL_ASSET"] else {
            throw XCTSkip("not set")
        }
        // Mirror the app path: extract the full audio track, then run the engine.
        let audioURL = try await Transcription.extractAudioTrack(from: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let result = try await Qwen3ASREngine.shared.transcribe(fileURL: audioURL)
        print("=== words 74-90s ===")
        for w in result.words where (w.start ?? 0) > 74 && (w.start ?? 0) < 90 {
            let d = (w.end ?? 0) - (w.start ?? 0)
            print(String(format: "%6.2f–%6.2f  %.2f  %@", w.start ?? -1, w.end ?? -1, d, w.text))
        }
    }
}
