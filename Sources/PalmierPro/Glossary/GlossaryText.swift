// Shared text primitives for the glossary — CJK detection and Latin word-boundary tests
// used by both the corrector (matching) and validation (variant length rules). refs feature/glossary

import Foundation

enum GlossaryText {
    /// True for CJK ideographs (the scripts where variants run together without spaces).
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,   // CJK Ext A
             0x4E00...0x9FFF,   // CJK Unified
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0x20000...0x2FA1F: // CJK Ext B+ / supplement
            return true
        default:
            return false
        }
    }

    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains(where: isCJK)
    }

    /// A Latin/ASCII-ish word character — used to test word boundaries so a Latin variant
    /// never matches inside a longer word. CJK characters are deliberately excluded.
    static func isLatinWordChar(_ c: Character) -> Bool {
        (c.isLetter || c.isNumber) && !isCJK(c)
    }

    /// Count of CJK characters in a string.
    static func cjkCount(_ s: String) -> Int {
        s.reduce(0) { $0 + (isCJK($1) ? 1 : 0) }
    }

    /// A phrase is treated as CJK when it contains any CJK character.
    static func isCJKPhrase(_ s: String) -> Bool {
        s.contains(where: isCJK)
    }

    /// Non-empty visible token count for a Latin phrase (words split on whitespace).
    static func latinWordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }
}
