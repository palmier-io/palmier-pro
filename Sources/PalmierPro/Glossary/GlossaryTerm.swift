// Glossary term model — the portable L1 correction vocabulary (canonical spelling + its ASR variants).
// Serialized as glossary.json; Palmier reads/writes it but does not own the format. refs feature/glossary

import Foundation

/// How much a correction is trusted. Everything except `inferred` auto-applies during materialisation.
enum GlossaryConfidence: String, Codable, Sendable, CaseIterable {
    case verified   // human-confirmed against the source (e.g. a frame)
    case declared   // user-stated
    case asserted   // promoted from a caption edit
    case inferred    // machine guess — surfaced as a suggestion, never auto-applied

    /// Verified/declared/asserted corrections are applied in materialisation; inferred ones never are.
    var autoApplies: Bool { self != .inferred }
}

/// Optional semantic category, used only for review/organisation.
enum GlossaryTermType: String, Codable, Sendable, CaseIterable {
    case person, place, shop, brand, dish, other
}

/// One canonical spelling and the ASR mis-hearings that should be corrected to it.
/// A term with no variants is bias-only (contributes a hotword, drives no find/replace).
struct GlossaryTerm: Codable, Sendable, Equatable {
    var canonical: String
    var variants: [String]
    var lang: String?
    var type: GlossaryTermType?
    var provenance: String
    var confidence: GlossaryConfidence
    var note: String?

    init(
        canonical: String,
        variants: [String] = [],
        lang: String? = nil,
        type: GlossaryTermType? = nil,
        provenance: String,
        confidence: GlossaryConfidence,
        note: String? = nil
    ) {
        self.canonical = canonical
        self.variants = variants
        self.lang = lang
        self.type = type
        self.provenance = provenance
        self.confidence = confidence
        self.note = note
    }

    // Tolerant decoding: a term without a usable canonical is dropped by the document decoder;
    // missing provenance/confidence fall back rather than failing the whole file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        canonical = (try? c.decode(String.self, forKey: .canonical)) ?? ""
        variants = ((try? c.decode([String].self, forKey: .variants)) ?? []).filter { !$0.isEmpty }
        lang = try? c.decodeIfPresent(String.self, forKey: .lang)
        type = (try? c.decodeIfPresent(String.self, forKey: .type)).flatMap { $0.flatMap(GlossaryTermType.init(rawValue:)) }
        provenance = (try? c.decodeIfPresent(String.self, forKey: .provenance)) ?? "user"
        confidence = (try? c.decodeIfPresent(String.self, forKey: .confidence))
            .flatMap { $0.flatMap(GlossaryConfidence.init(rawValue:)) } ?? .declared
        note = try? c.decodeIfPresent(String.self, forKey: .note)
    }

    private enum CodingKeys: String, CodingKey {
        case canonical, variants, lang, type, provenance, confidence, note
    }
}

/// The on-disk glossary file: a versioned list of terms.
struct GlossaryDocument: Codable, Sendable, Equatable {
    var version: Int
    var terms: [GlossaryTerm]

    init(version: Int = 1, terms: [GlossaryTerm] = []) {
        self.version = version
        self.terms = terms
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        // Drop terms with no canonical rather than rejecting the file.
        terms = ((try? c.decode([GlossaryTerm].self, forKey: .terms)) ?? [])
            .filter { !$0.canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private enum CodingKeys: String, CodingKey { case version, terms }
}
