// EditorViewModel+Glossary — the single source of truth for glossary add/remove/promote mutations,
// shared by the glossary MCP tools and the caption-tab glossary UI so both apply identical
// sanitization, bias republishing, and §5.2 caption resync. refs feature/glossary

import Foundation

extension EditorViewModel {
    struct GlossaryWriteResult { let term: GlossaryTerm; let warnings: [String] }

    /// Low-level upsert: sanitize against sibling canonicals, read-modify-write the scope's file, and
    /// republish the decoder bias. No caption resync — callers that need §5.2 use `glossaryAddTerm`.
    @discardableResult
    func glossaryWriteUpsert(_ term: GlossaryTerm, scope: GlossaryScope) throws -> GlossaryWriteResult {
        let otherCanonicals = Set(GlossaryStore.load(projectURL: projectURL).merged().map(\.term.canonical))
            .subtracting([term.canonical])
        let sanitized = GlossaryValidation.sanitize(term, otherCanonicals: otherCanonicals)
        var doc = try GlossaryStore.read(scope: scope, projectURL: projectURL)
        doc.terms.removeAll { $0.canonical == sanitized.term.canonical }
        doc.terms.append(sanitized.term)
        try GlossaryStore.write(doc, scope: scope, projectURL: projectURL)
        GlossaryStore.load(projectURL: projectURL).applyBias()
        return GlossaryWriteResult(term: sanitized.term, warnings: sanitized.warnings)
    }

    /// Full add path shared by glossary_add and the caption UI: upsert, then §5.2 resync exactly the
    /// caption clips that still show a variant when the term auto-applies.
    @discardableResult
    func glossaryAddTerm(_ term: GlossaryTerm, scope: GlossaryScope) throws -> GlossaryWriteResult {
        let result = try glossaryWriteUpsert(term, scope: scope)
        if result.term.confidence.autoApplies {
            resyncCaptionsForGlossaryTerm(strings: [result.term.canonical] + result.term.variants, trigger: "glossary_add")
        }
        return result
    }

    /// Full removal path: delete every matching-canonical entry from the scope, republish bias, and
    /// §5.2 resync the captions that showed it (they revert to whatever the transcript materialises).
    /// Returns the removed terms — empty when the canonical wasn't present.
    @discardableResult
    func glossaryRemoveTerm(canonical: String, scope: GlossaryScope) throws -> [GlossaryTerm] {
        var doc = try GlossaryStore.read(scope: scope, projectURL: projectURL)
        let removed = doc.terms.filter { $0.canonical == canonical }
        guard !removed.isEmpty else { return [] }
        doc.terms.removeAll { $0.canonical == canonical }
        try GlossaryStore.write(doc, scope: scope, projectURL: projectURL)
        GlossaryStore.load(projectURL: projectURL).applyBias()
        resyncCaptionsForGlossaryTerm(strings: [canonical] + removed.flatMap(\.variants), trigger: "glossary_remove")
        return removed
    }

    /// Full promote path shared by glossary_promote and the UI "Promote" action: move terms up the
    /// scope hierarchy (project→library→global) applying the higher-scope-wins collision rule, then
    /// republish bias. `canonical` nil/"all" promotes every matching term. Returns the promotion rows.
    @discardableResult
    func glossaryPromoteTerms(
        canonical: String?,
        confidence: GlossaryConfidence? = nil,
        from: GlossaryScope,
        to: GlossaryScope
    ) throws -> [GlossaryPromotion.Row] {
        guard from != to else { return [] }
        let fromDoc = try GlossaryStore.read(scope: from, projectURL: projectURL)
        let toDoc = try GlossaryStore.read(scope: to, projectURL: projectURL)
        let plan = GlossaryPromotion.plan(
            from: fromDoc, to: toDoc,
            fromWinsCollision: from.precedenceIndex > to.precedenceIndex,
            canonical: canonical, confidence: confidence
        )
        guard !plan.rows.isEmpty else { return [] }
        try GlossaryStore.write(plan.to, scope: to, projectURL: projectURL)
        try GlossaryStore.write(plan.from, scope: from, projectURL: projectURL)
        GlossaryStore.load(projectURL: projectURL).applyBias()
        return plan.rows
    }
}
