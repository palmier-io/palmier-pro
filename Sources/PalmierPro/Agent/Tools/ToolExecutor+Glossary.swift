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
    private static let glossaryPromoteAllowedKeys: Set<String> = ["canonical", "fromScope", "toScope", "confidence"]

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
        var notes: [String] = []
        let suggestions = rows.filter { ($0["confidence"] as? String) == GlossaryConfidence.inferred.rawValue }.count
        if suggestions > 0 {
            notes.append("\(suggestions) inferred term(s) are suggestions only and are not auto-applied.")
        }
        let projectAsserted = store.merged().filter {
            $0.scope == .project && $0.term.confidence == .asserted
        }.count
        if projectAsserted > 0 {
            notes.append("\(projectAsserted) asserted project-scope term(s) — glossary_promote moves them to library for reuse across projects.")
        }
        if !notes.isEmpty { payload["note"] = notes.joined(separator: " ") }
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
        // §5.2: re-derive exactly the captions that still show a variant of this term.
        if added.confidence.autoApplies {
            editor.resyncCaptionsForGlossaryTerm(strings: [added.canonical] + added.variants, trigger: "glossary_add")
            if let report = editor.takeResyncReport() { payload["captionResync"] = report.agentPayload }
        }
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
        glossaryStore(editor).applyBias()
        return (sanitized.term, sanitized.warnings)
    }

    /// Promote a classified caption edit into the library glossary as an asserted term. A caption-edit
    /// correction is speaker/domain-level knowledge, not project-level, so it lands in library to be
    /// reused across projects. Returns a response row, or nil if the variant was dropped by
    /// validation. Called from update_text's promotion hook. §6
    func promoteCaptionEdit(_ promotion: GlossaryClassifier.Promotion, clipId: String, editor: EditorViewModel) -> [String: Any]? {
        let term = GlossaryTerm(
            canonical: promotion.canonical,
            variants: [promotion.variant],
            provenance: "auto:caption-edit@\(clipId)",
            confidence: .asserted
        )
        guard let (added, _) = try? upsertGlossaryTerm(term, scope: .library, editor: editor),
              !added.variants.isEmpty else { return nil }
        return ["canonical": added.canonical, "variants": added.variants, "clipId": clipId]
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
        let removedTerms = doc.terms.filter { $0.canonical == canonical }
        doc.terms.removeAll { $0.canonical == canonical }
        let removed = doc.terms.count != before
        if removed {
            do { try GlossaryStore.write(doc, scope: scope, projectURL: editor.projectURL) }
            catch { throw ToolError("glossary_remove: could not write \(scope.rawValue) glossary: \(error.localizedDescription)") }
            glossaryStore(editor).applyBias()
        }
        var payload: [String: Any] = ["removed": removed, "canonical": canonical, "scope": scope.rawValue]
        // §5.2: captions showing the canonical revert to whatever the transcript now materialises.
        if removed {
            let strings = [canonical] + removedTerms.flatMap(\.variants)
            editor.resyncCaptionsForGlossaryTerm(strings: strings, trigger: "glossary_remove")
            if let report = editor.takeResyncReport() { payload["captionResync"] = report.agentPayload }
        }
        guard let json = Self.jsonString(payload) else { throw ToolError("glossary_remove: failed to encode") }
        return .ok(json)
    }

    // MARK: - glossary_promote

    /// Move terms up the sharing hierarchy (default project → library) so a correction made once is
    /// reused across projects. Selected terms are written into `toScope` and removed from `fromScope`.
    /// Collision (canonical already in `toScope`): the term from the higher-precedence scope wins —
    /// promoting project→library, the incoming project term overwrites the library entry.
    func glossaryPromote(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.glossaryPromoteAllowedKeys, path: "glossary_promote")
        let fromScope = try parseGlossaryScope(args["fromScope"], path: "glossary_promote.fromScope") ?? .project
        let toScope = try parseGlossaryScope(args["toScope"], path: "glossary_promote.toScope") ?? .library
        guard fromScope != toScope else {
            throw ToolError("glossary_promote: fromScope and toScope must differ.")
        }
        let confidenceFilter = try parseGlossaryConfidence(args["confidence"], path: "glossary_promote.confidence")
        let canonicalArg = args.string("canonical")?.trimmingCharacters(in: .whitespacesAndNewlines)

        let projectURL = editor.projectURL
        let fromDoc: GlossaryDocument
        let toDoc: GlossaryDocument
        do {
            fromDoc = try GlossaryStore.read(scope: fromScope, projectURL: projectURL)
            toDoc = try GlossaryStore.read(scope: toScope, projectURL: projectURL)
        } catch let error as GlossaryError {
            throw ToolError(error.errorDescription ?? "glossary scope unavailable")
        }

        let plan = GlossaryPromotion.plan(
            from: fromDoc, to: toDoc,
            fromWinsCollision: fromScope.precedenceIndex > toScope.precedenceIndex,
            canonical: canonicalArg, confidence: confidenceFilter
        )
        guard !plan.rows.isEmpty else {
            let target = (canonicalArg == nil || canonicalArg?.lowercased() == "all") ? nil : canonicalArg
            let payload: [String: Any] = [
                "promoted": [[String: Any]](), "count": 0,
                "fromScope": fromScope.rawValue, "toScope": toScope.rawValue,
                "note": target.map { "No term '\($0)' in \(fromScope.rawValue)." }
                    ?? "No terms in \(fromScope.rawValue) matched the filter.",
            ]
            guard let json = Self.jsonString(payload) else { throw ToolError("glossary_promote: failed to encode") }
            return .ok(json)
        }

        do {
            try GlossaryStore.write(plan.to, scope: toScope, projectURL: projectURL)
            try GlossaryStore.write(plan.from, scope: fromScope, projectURL: projectURL)
        } catch let error as GlossaryError {
            throw ToolError(error.errorDescription ?? "glossary scope unavailable")
        } catch {
            throw ToolError("glossary_promote: could not write glossary: \(error.localizedDescription)")
        }
        glossaryStore(editor).applyBias()

        let rows: [[String: Any]] = plan.rows.map { row in
            var out: [String: Any] = ["canonical": row.canonical]
            if let collision = row.collision { out["collision"] = "\(collision.rawValue)-\(toScope.rawValue)" }
            return out
        }
        let payload: [String: Any] = [
            "promoted": rows, "count": rows.count,
            "fromScope": fromScope.rawValue, "toScope": toScope.rawValue,
        ]
        guard let json = Self.jsonString(payload) else { throw ToolError("glossary_promote: failed to encode") }
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
