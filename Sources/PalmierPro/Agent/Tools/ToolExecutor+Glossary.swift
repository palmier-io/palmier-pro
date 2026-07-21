// Glossary MCP tools (glossary_list/add/remove/apply) plus the shared corrector helper the four
// transcript read paths use to materialise corrections at read time. refs feature/glossary

import Foundation

extension ToolExecutor {
    private static let glossaryAddAllowedKeys: Set<String> = [
        "canonical", "variants", "lang", "type", "provenance", "confidence", "note", "scope",
    ]
    private static let glossaryListAllowedKeys: Set<String> = ["scope", "confidence"]
    private static let glossaryRemoveAllowedKeys: Set<String> = ["canonical", "scope"]
    private static let glossaryApplyAllowedKeys: Set<String> = ["dryRun", "confidence"]

    /// The merged, read-only glossary for the editor's current project context.
    func glossaryStore(_ editor: EditorViewModel) -> GlossaryStore {
        GlossaryStore.load(projectURL: editor.projectURL)
    }

    /// Read-time corrector used by get_transcript, inspect_media, add_captions, and spoken search.
    func glossaryCorrector(_ editor: EditorViewModel) -> GlossaryCorrector {
        glossaryStore(editor).corrector()
    }

    // MARK: - glossary_list

    func glossaryList(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.glossaryListAllowedKeys, path: "glossary_list")
        let scopeFilter = try parseGlossaryScope(args["scope"], path: "glossary_list.scope")
        let confidenceFilter = try parseGlossaryConfidence(args["confidence"], path: "glossary_list.confidence")

        let store = glossaryStore(editor)
        var rows: [[String: Any]] = []
        for merged in store.merged() {
            if let scopeFilter, merged.scope != scopeFilter { continue }
            if let confidenceFilter, merged.term.confidence != confidenceFilter { continue }
            rows.append(Self.termRow(merged))
        }

        var payload: [String: Any] = ["terms": rows]
        let warnings = store.allWarnings()
        if !warnings.isEmpty { payload["warnings"] = warnings }
        let suggestions = rows.filter { ($0["confidence"] as? String) == GlossaryConfidence.inferred.rawValue }.count
        if suggestions > 0 {
            payload["note"] = "\(suggestions) inferred term(s) are suggestions only and are not auto-applied."
        }
        guard let json = Self.jsonString(payload) else { throw ToolError("glossary_list: failed to encode") }
        return .ok(json)
    }

    private static func termRow(_ merged: MergedGlossaryTerm) -> [String: Any] {
        let t = merged.term
        var row: [String: Any] = [
            "canonical": t.canonical,
            "scope": merged.scope.rawValue,
            "confidence": t.confidence.rawValue,
            "provenance": t.provenance,
            "autoApplied": t.confidence.autoApplies,
        ]
        if !t.variants.isEmpty { row["variants"] = t.variants }
        if let lang = t.lang { row["lang"] = lang }
        if let type = t.type { row["type"] = type.rawValue }
        if let note = t.note { row["note"] = note }
        return row
    }

    // MARK: - glossary_add

    func glossaryAdd(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.glossaryAddAllowedKeys, path: "glossary_add")
        let canonical = try args.requireString("canonical").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else { throw ToolError("glossary_add: canonical must not be empty") }

        let variants = args.stringArray("variants")
        let confidence = try parseGlossaryConfidence(args["confidence"], path: "glossary_add.confidence") ?? .declared
        let type = try parseGlossaryTermType(args["type"], path: "glossary_add.type")
        let scope = try parseGlossaryScope(args["scope"], path: "glossary_add.scope") ?? .project
        let provenance = args.string("provenance") ?? "user"

        let term = GlossaryTerm(
            canonical: canonical,
            variants: variants,
            lang: args.string("lang"),
            type: type,
            provenance: provenance,
            confidence: confidence,
            note: args.string("note")
        )

        let (added, warnings) = try upsertGlossaryTerm(term, scope: scope, editor: editor)
        var payload: [String: Any] = ["added": Self.termRow(MergedGlossaryTerm(term: added, scope: scope))]
        if !warnings.isEmpty { payload["warnings"] = warnings }
        guard let json = Self.jsonString(payload) else { throw ToolError("glossary_add: failed to encode") }
        return .ok(json)
    }

    /// Validate, then upsert `term` into `scope`'s file (replacing any existing same-canonical entry).
    private func upsertGlossaryTerm(_ term: GlossaryTerm, scope: GlossaryScope, editor: EditorViewModel) throws -> (GlossaryTerm, [String]) {
        let projectURL = editor.projectURL
        // Collision warnings reference every OTHER canonical in the merged glossary.
        let otherCanonicals = Set(glossaryStore(editor).merged().map(\.term.canonical)).subtracting([term.canonical])
        let sanitized = GlossaryValidation.sanitize(term, otherCanonicals: otherCanonicals)

        var doc: GlossaryDocument
        do {
            doc = try GlossaryStore.read(scope: scope, projectURL: projectURL)
        } catch let error as GlossaryError {
            throw ToolError(error.errorDescription ?? "glossary scope unavailable")
        }
        doc.terms.removeAll { $0.canonical == sanitized.term.canonical }
        doc.terms.append(sanitized.term)
        do {
            try GlossaryStore.write(doc, scope: scope, projectURL: projectURL)
        } catch let error as GlossaryError {
            throw ToolError(error.errorDescription ?? "glossary scope unavailable")
        } catch {
            throw ToolError("glossary_add: could not write \(scope.rawValue) glossary: \(error.localizedDescription)")
        }
        return (sanitized.term, sanitized.warnings)
    }

    /// Promote a classified caption edit into the project glossary as an asserted term.
    /// Returns a response row, or nil if the project scope is unavailable or the variant was
    /// dropped by validation. Called from update_text's promotion hook. §6
    func promoteCaptionEdit(_ promotion: GlossaryClassifier.Promotion, clipId: String, editor: EditorViewModel) -> [String: Any]? {
        // Merge with any existing same-canonical project entry — several caption clips can carry
        // DIFFERENT mis-hearings of one canonical in a single update_text; upsert-replace would
        // silently keep only the last variant.
        let existing = (try? GlossaryStore.read(scope: .project, projectURL: editor.projectURL))?
            .terms.first { $0.canonical == promotion.canonical }
        var variants = existing?.variants ?? []
        if !variants.contains(promotion.variant) { variants.append(promotion.variant) }
        // A user actively typed this correction: the merged term is at least .asserted, so it
        // auto-applies. Higher existing confidence (declared/verified) is kept; merging into an
        // inferred (suggestion-only) entry must not leave the user's own edit suggestion-only.
        let confidence = existing.map { $0.confidence.autoApplies ? $0.confidence : .asserted } ?? .asserted
        let term = GlossaryTerm(
            canonical: promotion.canonical,
            variants: variants,
            provenance: existing?.provenance ?? "auto:caption-edit@\(clipId)",
            confidence: confidence
        )
        do {
            let (added, _) = try upsertGlossaryTerm(term, scope: .project, editor: editor)
            guard !added.variants.isEmpty else { return nil }
            return ["canonical": added.canonical, "variants": added.variants, "clipId": clipId]
        } catch {
            // A failed write must not masquerade as "nothing to promote" — the caption edit looked
            // learned but wasn't persisted. Log and surface for the tool response.
            Log.agent.warning("caption-edit promotion write failed clip=\(clipId): \(error.localizedDescription)")
            return ["canonical": promotion.canonical, "clipId": clipId,
                    "error": "glossary write failed: \(error.localizedDescription)"]
        }
    }

    // MARK: - glossary_remove

    func glossaryRemove(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.glossaryRemoveAllowedKeys, path: "glossary_remove")
        let canonical = try args.requireString("canonical").trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = try parseGlossaryScope(args["scope"], path: "glossary_remove.scope") ?? .project

        var doc: GlossaryDocument
        do {
            doc = try GlossaryStore.read(scope: scope, projectURL: editor.projectURL)
        } catch let error as GlossaryError {
            throw ToolError(error.errorDescription ?? "glossary scope unavailable")
        }
        let before = doc.terms.count
        doc.terms.removeAll { $0.canonical == canonical }
        let removed = doc.terms.count != before
        if removed {
            do { try GlossaryStore.write(doc, scope: scope, projectURL: editor.projectURL) }
            catch { throw ToolError("glossary_remove: could not write \(scope.rawValue) glossary: \(error.localizedDescription)") }
        }
        let payload: [String: Any] = ["removed": removed, "canonical": canonical, "scope": scope.rawValue]
        guard let json = Self.jsonString(payload) else { throw ToolError("glossary_remove: failed to encode") }
        return .ok(json)
    }

    // MARK: - glossary_apply

    func glossaryApply(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.glossaryApplyAllowedKeys, path: "glossary_apply")
        let dryRun = args.bool("dryRun") ?? true
        let confidenceFilter = try parseGlossaryConfidence(args["confidence"], path: "glossary_apply.confidence")

        let store = glossaryStore(editor)
        var terms = store.autoApplyTerms
        if let confidenceFilter, confidenceFilter.autoApplies {
            terms = terms.filter { $0.confidence == confidenceFilter }
        } else if let confidenceFilter {
            terms = []  // inferred never applies
        }
        let corrector = GlossaryCorrector(terms: terms)

        var scanned = 0
        var changedSegments = 0
        var examples: [[String: String]] = []
        for asset in editor.mediaAssets where asset.type == .video || asset.type == .audio {
            guard let transcript = TranscriptCache.cachedOnDisk(for: asset.url) else { continue }
            scanned += 1
            guard !corrector.isEmpty else { continue }
            for segment in transcript.segments {
                let corrected = corrector.correct(segment.text)
                guard corrected != segment.text else { continue }
                changedSegments += 1
                if examples.count < 10 {
                    examples.append(["raw": segment.text, "corrected": corrected])
                }
            }
        }

        if !dryRun {
            await TranscriptCache.shared.clearMemory()
        }

        var payload: [String: Any] = [
            "dryRun": dryRun,
            "scannedTranscripts": scanned,
            "changedSegments": changedSegments,
            "appliedTerms": terms.count,
            "note": "Corrections are applied at read time (get_transcript, inspect_media, add_captions, spoken search); the raw cached transcripts on disk stay raw."
                + (dryRun ? "" : " In-memory transcript caches were dropped so the next read rebuilds the corrected view."),
        ]
        if !examples.isEmpty { payload["examples"] = examples }
        let inferred = store.merged().filter { !$0.term.confidence.autoApplies }.map(\.term.canonical)
        if !inferred.isEmpty { payload["inferredSuggestions"] = inferred }
        let warnings = store.allWarnings()
        if !warnings.isEmpty { payload["warnings"] = warnings }
        guard let json = Self.jsonString(payload) else { throw ToolError("glossary_apply: failed to encode") }
        return .ok(json)
    }

    // MARK: - Parsing helpers

    private func parseGlossaryScope(_ raw: Any?, path: String) throws -> GlossaryScope? {
        guard let raw else { return nil }
        guard let s = raw as? String, let scope = GlossaryScope(rawValue: s) else {
            throw ToolError("\(path): must be one of \(GlossaryScope.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return scope
    }

    private func parseGlossaryConfidence(_ raw: Any?, path: String) throws -> GlossaryConfidence? {
        guard let raw else { return nil }
        guard let s = raw as? String, let confidence = GlossaryConfidence(rawValue: s) else {
            throw ToolError("\(path): must be one of \(GlossaryConfidence.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return confidence
    }

    private func parseGlossaryTermType(_ raw: Any?, path: String) throws -> GlossaryTermType? {
        guard let raw else { return nil }
        guard let s = raw as? String, let type = GlossaryTermType(rawValue: s) else {
            throw ToolError("\(path): must be one of \(GlossaryTermType.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return type
    }
}
