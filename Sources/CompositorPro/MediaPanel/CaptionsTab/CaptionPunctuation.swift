import Foundation

enum CaptionPunctuation {
    static func normalized(_ content: String) -> String {
        var suffixStart = content.endIndex
        while suffixStart > content.startIndex {
            let previous = content.index(before: suffixStart)
            guard content[previous].isWhitespace || content[previous] == "," else { break }
            suffixStart = previous
        }
        let suffix = content[suffixStart...]
        guard suffix.contains(",") else { return content }
        return String(content[..<suffixStart]) + suffix.replacingOccurrences(of: ",", with: "")
    }

    static func normalized(_ words: [WordTiming]?) -> [WordTiming]? {
        guard var words else { return nil }
        for index in words.indices.reversed() {
            words[index].text = normalized(words[index].text)
            if words[index].text.contains(where: { !$0.isWhitespace }) { break }
        }
        return words
    }
}
