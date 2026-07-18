// Shared caption tokenizer — splits caption text into the same "words" the renderer animates and
// the retimer aligns: whitespace-separated Latin/number runs, with each CJK character standing
// alone (CJK has no spaces, so per-character is the unit of karaoke). Kept free of Glossary so the
// retimer and renderer share one definition of a token without coupling to term correction.
import Foundation

enum CaptionText {
    /// CJK ideographs / compatibility forms — the scripts we tokenize per character.
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let value = Int(scalar.value)
        return (0x2E80...0x9FFF).contains(value) || (0xF900...0xFAFF).contains(value)
    }

    /// Token strings in order. A CJK scalar is its own token; other runs break on whitespace only
    /// (so "U.S." and "York," stay whole), matching TextFrameRenderer's word boundaries.
    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var run = ""
        func flush() { if !run.isEmpty { out.append(run); run = "" } }
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                flush()
            } else if isCJK(scalar) {
                flush()
                out.append(String(scalar))
            } else {
                run.unicodeScalars.append(scalar)
            }
        }
        flush()
        return out
    }

    /// Lowercased comparison key (letters/digits/CJK only); "" for punctuation-only tokens, which
    /// must never anchor an alignment.
    static func matchKey(_ token: String) -> String {
        String(token.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || isCJK($0)
        })
    }
}
