// GlossaryValidation — variant safety (§5.4): reject too-short variants that would corrupt longer
// terms, drop no-op variants, and warn on collisions with another term's canonical. refs feature/glossary

import Foundation

enum GlossaryValidation {
    /// Minimum lengths below which a variant is unsafe to find/replace.
    static let minCJKChars = 2
    static let minLatinChars = 3

    struct Result {
        let term: GlossaryTerm       // sanitized: unsafe variants removed
        let warnings: [String]
        let rejectedVariants: [String]
    }

    /// Sanitize `term`, dropping variants that are too short, empty, equal to the canonical, or
    /// duplicated. Warns (does not drop) when a kept variant collides with another term's canonical.
    /// `otherCanonicals` is the set of canonicals from the rest of the merged glossary.
    static func sanitize(_ term: GlossaryTerm, otherCanonicals: Set<String>) -> Result {
        var kept: [String] = []
        var warnings: [String] = []
        var rejected: [String] = []
        var seen = Set<String>()

        let canonical = term.canonical.trimmingCharacters(in: .whitespacesAndNewlines)

        for raw in term.variants {
            let variant = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if variant.isEmpty {
                // A whitespace-only variant normalizes to "" and would match empty spans (corrupting
                // output); reject it explicitly. A truly empty "" is skipped silently.
                if !raw.isEmpty {
                    rejected.append(raw)
                    warnings.append("Variant is whitespace-only and was dropped — it would match empty text.")
                }
                continue
            }
            if variant == canonical {
                rejected.append(raw)
                warnings.append("Variant '\(variant)' equals the canonical and was dropped (no-op).")
                continue
            }
            guard seen.insert(variant).inserted else { continue }

            if let reason = tooShortReason(variant) {
                rejected.append(variant)
                warnings.append("Variant '\(variant)' rejected: \(reason). Short variants corrupt longer words.")
                continue
            }
            if otherCanonicals.contains(variant) {
                warnings.append("Variant '\(variant)' collides with another term's canonical — it will now be rewritten to '\(canonical)'.")
            }
            kept.append(variant)
        }

        var sanitized = term
        sanitized.canonical = canonical
        sanitized.variants = kept
        return Result(term: sanitized, warnings: warnings, rejectedVariants: rejected)
    }

    /// Returns a human reason when a variant is below the safe length for its script, else nil.
    static func tooShortReason(_ variant: String) -> String? {
        if GlossaryText.isCJKPhrase(variant) {
            let n = GlossaryText.cjkCount(variant)
            if n < minCJKChars { return "only \(n) CJK character(s), minimum \(minCJKChars)" }
        } else if variant.count < minLatinChars {
            return "only \(variant.count) character(s), minimum \(minLatinChars)"
        }
        return nil
    }
}
