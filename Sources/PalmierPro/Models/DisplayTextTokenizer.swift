import Foundation
import NaturalLanguage

enum DisplayTextTokenizer {
    struct Token: Equatable {
        let range: Range<String.Index>
        let text: String
    }

    static func wordTokens(in text: String) -> [Token] {
        guard !text.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var tokens: [Token] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let tokenText = String(text[range])
            if containsWordCharacter(tokenText) {
                tokens.append(Token(range: range, text: tokenText))
            }
            return true
        }

        return tokens.isEmpty ? fallbackWhitespaceTokens(in: text) : tokens
    }

    static func nsWordTokens(in text: String) -> [(range: NSRange, text: String)] {
        wordTokens(in: text).map { token in
            (NSRange(token.range, in: text), token.text)
        }
    }

    static func wordCount(_ text: String) -> Int {
        wordTokens(in: text).count
    }

    static func splitAtBalancedWordBoundary(_ text: String) -> [String]? {
        let tokens = wordTokens(in: text)
        guard tokens.count > 1 else { return nil }

        let total = visibleCharacterCount(text)
        guard total > 1 else { return nil }
        let target = Double(total) / 2

        let boundaries = tokens.dropFirst().map(\.range.lowerBound)
        guard let boundary = boundaries.min(by: { lhs, rhs in
            abs(Double(visibleCharacterCount(String(text[..<lhs]))) - target)
                < abs(Double(visibleCharacterCount(String(text[..<rhs]))) - target)
        }) else { return nil }

        let left = String(text[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(text[boundary...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        return [left, right]
    }

    static func splitByVisibleCharacterLimit(_ text: String, maxVisibleCharacters: Int) -> [String]? {
        guard maxVisibleCharacters > 0 else { return nil }
        let tokens = wordTokens(in: text)
        guard !tokens.isEmpty else { return nil }

        let boundaries = tokens.dropFirst().map(\.range.lowerBound) + [text.endIndex]
        var pieces: [String] = []
        var start = text.startIndex
        var lastAccepted: String.Index?
        var index = 0

        while index < boundaries.count {
            let boundary = boundaries[index]
            let candidate = String(text[start..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.isEmpty {
                index += 1
                continue
            }

            if visibleCharacterCount(candidate) <= maxVisibleCharacters || lastAccepted == nil {
                lastAccepted = boundary
                index += 1
            } else if let accepted = lastAccepted {
                let piece = String(text[start..<accepted]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { pieces.append(piece) }
                start = accepted
                lastAccepted = nil
            }
        }

        let tail = String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces.isEmpty ? nil : pieces
    }

    static func visibleCharacterCount(_ text: String) -> Int {
        text.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
    }

    private static func containsWordCharacter(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    private static func fallbackWhitespaceTokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var i = text.startIndex

        while i < text.endIndex {
            while i < text.endIndex, text[i].isWhitespace {
                i = text.index(after: i)
            }
            guard i < text.endIndex else { break }
            let start = i
            while i < text.endIndex, !text[i].isWhitespace {
                i = text.index(after: i)
            }
            let tokenText = String(text[start..<i])
            if containsWordCharacter(tokenText) {
                tokens.append(Token(range: start..<i, text: tokenText))
            }
        }

        return tokens
    }
}
