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

        // Regression (bug report 2026-07-15): punctuation is silent — near-zero duration.
        for word in result.words where Qwen3ASREngineTests.isPunctuation(word.text) {
            let duration = (word.end ?? 0) - (word.start ?? 0)
            XCTAssertLessThanOrEqual(duration, 0.05, "punctuation '\(word.text)' allocated speech time")
        }

        // Regression: long CJK runs must not be uniformly divided (stdev of durations > 0).
        var run: [Double] = []
        func checkRun() {
            guard run.count >= 14 else { run = []; return }
            let mean = run.reduce(0, +) / Double(run.count)
            let variance = run.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(run.count)
            XCTAssertGreaterThan(variance.squareRoot(), 0.001,
                "CJK run of \(run.count) words has uniform durations — interpolation, not alignment")
            run = []
        }
        for word in result.words {
            let isCJK = word.text.unicodeScalars.contains { (0x4E00...0x9FFF).contains(Int($0.value)) }
            if isCJK, let start = word.start, let end = word.end {
                run.append(end - start)
            } else if !Qwen3ASREngineTests.isPunctuation(word.text) {
                checkRun()
            }
        }
        checkRun()

        // Regression (bug report follow-up): on anchorable audio, most CJK words must be
        // genuinely aligned; anything interpolated must carry aligned == false so callers
        // can tell fabricated timing from aligned timing.
        let cjkWords = result.words.filter { w in
            w.text.unicodeScalars.contains { (0x4E00...0x9FFF).contains(Int($0.value)) }
        }
        if !cjkWords.isEmpty {
            let alignedCount = cjkWords.filter { $0.aligned == true }.count
            XCTAssertGreaterThan(Double(alignedCount) / Double(cjkWords.count), 0.5,
                "most CJK words should be anchor-aligned on clean audio (\(alignedCount)/\(cjkWords.count))")
        }
    }

    private static func isPunctuation(_ text: String) -> Bool {
        !text.unicodeScalars.contains {
            let value = Int($0.value)
            if (0x3000...0x303F).contains(value) { return false }
            return CharacterSet.alphanumerics.contains($0) || (0x2E80...0x9FFF).contains(value)
        }
    }
}
