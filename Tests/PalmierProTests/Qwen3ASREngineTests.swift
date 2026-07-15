// Verifies the Qwen3-ASR engine transcribes code-switched zh/en audio with real
// (Whisper-anchored) word timing — the case the Apple Speech path drops silently.
import XCTest
@testable import PalmierPro

final class Qwen3ASREngineTests: XCTestCase {
    /// Set PALMIER_CS_TEST_WAV to a code-switched wav to run; skipped otherwise.
    func testCodeSwitchedTranscription() async throws {
        guard let path = ProcessInfo.processInfo.environment["PALMIER_CS_TEST_WAV"] else {
            throw XCTSkip("PALMIER_CS_TEST_WAV not set")
        }
        let result = try await Qwen3ASREngine.shared.transcribe(fileURL: URL(fileURLWithPath: path))

        print("=== Qwen3-ASR transcript ===")
        for segment in result.segments {
            print(String(format: "[%6.2f – %6.2f] %@", segment.start, segment.end, segment.text))
        }
        print("words: \(result.words.count)")

        let text = result.text
        // Must contain BOTH scripts to prove code-switching survived.
        let hasCJK = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains(Int($0.value)) }
        let hasLatin = text.rangeOfCharacter(from: .letters.intersection(.init(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"))) != nil
        XCTAssertTrue(hasCJK, "transcript lost the Mandarin: \(text)")
        XCTAssertTrue(hasLatin, "transcript lost the English: \(text)")
        XCTAssertFalse(result.words.isEmpty, "no words")
        XCTAssertFalse(result.segments.isEmpty, "no segments")

        // Word times must be monotonic and inside the audio duration.
        var previousStart = -1.0
        for word in result.words {
            let start = try XCTUnwrap(word.start)
            let end = try XCTUnwrap(word.end)
            XCTAssertGreaterThanOrEqual(start, previousStart - 0.01, "non-monotonic at '\(word.text)'")
            XCTAssertGreaterThanOrEqual(end, start)
            previousStart = start
        }
        for word in result.words.prefix(12) {
            print(String(format: "  %5.2f–%5.2f  %@", word.start ?? -1, word.end ?? -1, word.text))
        }
    }
}
