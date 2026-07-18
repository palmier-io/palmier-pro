// GlossaryStore — loads and layers the glossary (global → library → project, later wins per canonical),
// exposes the merged view, builds the read-time corrector, and reads/writes per-scope files. refs feature/glossary

import CryptoKit
import Foundation

/// A glossary layer. Precedence runs global (weakest) → library → project (strongest):
/// a later layer's entry for a canonical replaces an earlier one.
enum GlossaryScope: String, Codable, Sendable, CaseIterable {
    case global
    case library
    case project

    /// Resolution order, weakest first.
    static let precedence: [GlossaryScope] = [.global, .library, .project]

    /// Position in the resolution order — higher means it wins at read time (project strongest).
    var precedenceIndex: Int { Self.precedence.firstIndex(of: self) ?? 0 }

    /// Test seam: redirects the process-global library/global roots to an isolated directory. nil in
    /// production (real user paths). Task-local so parallel tests each get their own root with no race.
    @TaskLocal static var sharedRootOverride: URL?

    /// The glossary.json for this scope, or nil when unavailable (e.g. project scope with no open project).
    func fileURL(projectURL: URL?) -> URL? {
        switch self {
        case .global:
            let root = Self.sharedRootOverride
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/glossary", isDirectory: true)
            return root.appendingPathComponent("global.json", isDirectory: false)
        case .library:
            // No cross-project media-library root exists; the shared storage dir is the closest concept.
            let root = Self.sharedRootOverride ?? Project.storageDirectory
            return root.appendingPathComponent(Project.glossaryFilename, isDirectory: false)
        case .project:
            return projectURL?.appendingPathComponent(Project.glossaryFilename, isDirectory: false)
        }
    }
}

/// A merged term plus the layer it won from.
struct MergedGlossaryTerm: Sendable {
    let term: GlossaryTerm
    let scope: GlossaryScope
}

/// The layered, read-only glossary for one project context.
struct GlossaryStore: Sendable {
    struct Layer: Sendable {
        let scope: GlossaryScope
        let document: GlossaryDocument
    }

    let layers: [Layer]
    /// Human-readable load problems (malformed files) — surfaced as tool notes, never fatal.
    let warnings: [String]

    /// Load and layer all available scopes for `projectURL`. Missing files are skipped silently;
    /// malformed files warn and are skipped so materialisation proceeds unbiased.
    static func load(projectURL: URL?) -> GlossaryStore {
        var layers: [Layer] = []
        var warnings: [String] = []
        for scope in GlossaryScope.precedence {
            guard let url = scope.fileURL(projectURL: projectURL),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let data = try Data(contentsOf: url)
                let doc = try JSONDecoder().decode(GlossaryDocument.self, from: data)
                layers.append(Layer(scope: scope, document: doc))
            } catch {
                warnings.append("\(scope.rawValue) glossary could not be read (\(url.lastPathComponent)); proceeding without it.")
                Log.agent.warning("glossary load failed scope=\(scope.rawValue) error=\(error.localizedDescription)")
            }
        }
        return GlossaryStore(layers: layers, warnings: warnings)
    }

    /// Merged terms, later scope winning per canonical. Order is stable (by canonical).
    func merged() -> [MergedGlossaryTerm] {
        var byCanonical: [String: MergedGlossaryTerm] = [:]
        for layer in layers {  // precedence order: later overwrites
            for term in layer.document.terms {
                byCanonical[term.canonical] = MergedGlossaryTerm(term: term, scope: layer.scope)
            }
        }
        return byCanonical.values.sorted { $0.term.canonical < $1.term.canonical }
    }

    /// Auto-apply terms (verified/declared/asserted) with §5.4 variant sanitization applied.
    /// Sanitizing at READ time — not only in glossary_add — means a hand-authored glossary.json
    /// can never feed an unsafe short variant into the corrector (e.g. 师→狮 corrupting 老师).
    var autoApplyTerms: [GlossaryTerm] {
        sanitizedAutoApply().terms
    }

    /// Read-time corrector built from the sanitized auto-apply terms. Empty when nothing auto-applies.
    func corrector() -> GlossaryCorrector {
        GlossaryCorrector(terms: autoApplyTerms)
    }

    /// Sanitized auto-apply terms plus warnings for any variant dropped at read time. Every read
    /// path that shows warnings (glossary_list, glossary_apply) should surface these alongside
    /// `warnings` so a hand-author can see why an entry didn't apply.
    func sanitizedAutoApply() -> (terms: [GlossaryTerm], warnings: [String]) {
        let mergedTerms = merged()
        let allCanonicals = Set(mergedTerms.map(\.term.canonical))
        var terms: [GlossaryTerm] = []
        var dropWarnings: [String] = []
        for m in mergedTerms where m.term.confidence.autoApplies {
            let result = GlossaryValidation.sanitize(
                m.term, otherCanonicals: allCanonicals.subtracting([m.term.canonical])
            )
            if !result.rejectedVariants.isEmpty {
                dropWarnings.append(
                    "Term '\(m.term.canonical)' (\(m.scope.rawValue)): dropped unsafe variant(s) "
                        + "\(result.rejectedVariants.joined(separator: ", ")) — too short to apply safely."
                )
            }
            terms.append(result.term)
        }
        return (terms, dropWarnings)
    }

    /// Load warnings (malformed files) plus read-time sanitization warnings.
    func allWarnings() -> [String] {
        warnings + sanitizedAutoApply().warnings
    }

    /// Canonicals that should bias the decoder (auto-apply confidences only). §4
    func hotwordTerms() -> [String] {
        autoApplyTerms.map(\.canonical).sorted()
    }

    /// Stable fingerprint of the biasing terms, for salting a transcription cache key so changed
    /// hotwords force a fresh transcription. §4
    func biasFingerprint() -> String {
        let material = autoApplyTerms
            .map { "\($0.canonical)=\($0.variants.sorted().joined(separator: ","))" }
            .sorted()
            .joined(separator: "\n")
        guard !material.isEmpty else { return "none" }
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// Publish this store's hotwords to the transcription engines (TranscriptionBias). Call from
    /// project-aware paths before transcribing and after any glossary write. §4
    func applyBias() {
        TranscriptionBias.update(hotwords: hotwordTerms(), fingerprint: biasFingerprint())
    }

    // MARK: - Per-scope reads/writes

    /// Read one scope's document (empty when the file is missing).
    static func read(scope: GlossaryScope, projectURL: URL?) throws -> GlossaryDocument {
        guard let url = scope.fileURL(projectURL: projectURL) else {
            throw GlossaryError.scopeUnavailable(scope)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return GlossaryDocument() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GlossaryDocument.self, from: data)
    }

    /// Write one scope's document, creating parent directories as needed.
    static func write(_ document: GlossaryDocument, scope: GlossaryScope, projectURL: URL?) throws {
        guard let url = scope.fileURL(projectURL: projectURL) else {
            throw GlossaryError.scopeUnavailable(scope)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }
}

enum GlossaryError: LocalizedError {
    case scopeUnavailable(GlossaryScope)

    var errorDescription: String? {
        switch self {
        case .scopeUnavailable(.project):
            return "No open project — glossary scope 'project' is unavailable. Use scope 'global' or 'library'."
        case .scopeUnavailable(let scope):
            return "Glossary scope '\(scope.rawValue)' is unavailable."
        }
    }
}
