import Foundation
import Tokenizers

final class TextTokenizer: @unchecked Sendable {
    private let tokenizer: Tokenizer
    private let contextLength: Int
    private let padToken: Int32 = 0

    init(tokenizerFolder: URL, contextLength: Int) async throws {
        tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerFolder)
        self.contextLength = contextLength
    }

    /// SigLIP was trained on max_length-padded sequences with no attention
    /// mask, so padding must match the Python reference exactly.
    func tokenize(_ text: String) -> [Int32] {
        var ids = tokenizer.encode(text: text).map(Int32.init)
        if ids.count > contextLength {
            ids = Array(ids.prefix(contextLength))
        }
        ids += Array(repeating: padToken, count: contextLength - ids.count)
        return ids
    }
}
