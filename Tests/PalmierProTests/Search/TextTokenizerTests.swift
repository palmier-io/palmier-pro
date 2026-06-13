import Foundation
import Testing
@testable import PalmierPro

/// Token-for-token parity with the Python reference. Requires Phase-0 artifacts
/// (the tokenizer ships with the model download); skipped otherwise.
@Suite("TextTokenizer")
struct TextTokenizerTests {
    static var tokenizerFolder: URL {
        VisualEmbedderParityTests.buildDir.appendingPathComponent("tokenizer", isDirectory: true)
    }
    static var artifactsExist: Bool {
        FileManager.default.fileExists(atPath: tokenizerFolder.appendingPathComponent("tokenizer.json").path)
    }

    @Test(.enabled(if: artifactsExist)) func matchesPythonGoldens() async throws {
        let tokenizer = try await TextTokenizer(tokenizerFolder: Self.tokenizerFolder, contextLength: 64)
        for (text, expected) in TextTokenizerGoldens.cases {
            #expect(tokenizer.tokenize(text) == expected, "mismatch for \(text)")
        }
    }

    @Test(.enabled(if: artifactsExist)) func padsAndTruncates() async throws {
        let tokenizer = try await TextTokenizer(tokenizerFolder: Self.tokenizerFolder, contextLength: 64)
        let short = tokenizer.tokenize("a cat")
        #expect(short.count == 64)
        #expect(short.last == 0)

        let long = tokenizer.tokenize(Array(repeating: "establishing shot", count: 80).joined(separator: " "))
        #expect(long.count == 64)
        #expect(long.allSatisfy { $0 != 0 })
    }
}
