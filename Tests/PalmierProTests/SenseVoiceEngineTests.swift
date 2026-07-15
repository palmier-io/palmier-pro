// Verifies the SenseVoice engine transcribes code-switched zh/en audio — the exact
// case the Apple Speech path drops (it locks to one locale from system settings).
import XCTest
@testable import PalmierPro

final class SenseVoiceEngineTests: XCTestCase {
    /// Set PALMIER_CS_TEST_WAV to a code-switched wav to run; skipped otherwise.
    func testCodeSwitchedTranscription() async throws {
        guard let path = ProcessInfo.processInfo.environment["PALMIER_CS_TEST_WAV"] else {
            throw XCTSkip("PALMIER_CS_TEST_WAV not set")
        }
        let result = try await SenseVoiceEngine.shared.transcribe(fileURL: URL(fileURLWithPath: path))

        print("=== SenseVoice transcript ===")
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
        XCTAssertFalse(result.words.isEmpty, "no word timestamps")
        XCTAssertFalse(result.segments.isEmpty, "no segments")
    }
}
