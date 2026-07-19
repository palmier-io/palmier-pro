// Parity tests for EditorViewModel's shared glossary helpers (the caption-tab glossary UI's path)
// against the glossary_* tool semantics, plus the per-project transcription-model persistence round
// trip behind B2's Model row.

import Foundation
import Testing
@testable import PalmierPro

@Suite("Glossary UI helpers", .isolatedGlossaryRoot)
@MainActor
struct GlossaryUIHelperTests {
    private func makeProject() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gloss-ui-\(UUID().uuidString).palmier", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func editor(project: URL) -> EditorViewModel {
        let e = EditorViewModel()
        e.projectURL = project
        return e
    }

    private func term(_ canonical: String, _ variants: [String], confidence: GlossaryConfidence) -> GlossaryTerm {
        GlossaryTerm(canonical: canonical, variants: variants, provenance: "user", confidence: confidence)
    }

    // The UI add path must write exactly what glossary_add writes for the same inputs (same sanitize,
    // same scope file) — that is what makes the extraction a true single source of truth.
    @Test func addTermMatchesGlossaryAddToolWrite() async throws {
        let toolDir = try makeProject(); defer { try? FileManager.default.removeItem(at: toolDir) }
        let uiDir = try makeProject(); defer { try? FileManager.default.removeItem(at: uiDir) }
        let canonical = "Term\(UUID().uuidString.prefix(6))"
        let variants = ["variantone", "varianttwo"]

        let h = ToolHarness()
        h.editor.projectURL = toolDir
        _ = try await h.runOK("glossary_add", args: [
            "canonical": canonical, "variants": variants, "confidence": "declared", "scope": "project",
        ])

        _ = try editor(project: uiDir).glossaryAddTerm(
            term(canonical, variants, confidence: .declared), scope: .project
        )

        let toolDoc = try GlossaryStore.read(scope: .project, projectURL: toolDir)
        let uiDoc = try GlossaryStore.read(scope: .project, projectURL: uiDir)
        #expect(!toolDoc.terms.isEmpty)
        #expect(toolDoc.terms == uiDoc.terms)
    }

    // add validates: an unsafe short variant is dropped by sanitization before it can bias the decoder.
    @Test func addTermSanitizesUnsafeVariant() throws {
        let dir = try makeProject(); defer { try? FileManager.default.removeItem(at: dir) }
        let result = try editor(project: dir).glossaryAddTerm(
            term("老师", ["师"], confidence: .declared), scope: .project
        )
        #expect(result.term.canonical == "老师")
        #expect(!result.term.variants.contains("师"))
        #expect(!result.warnings.isEmpty)
    }

    // remove returns the removed term and clears it from the scope file (bias republished around it).
    @Test func removeTermDeletesFromScope() throws {
        let dir = try makeProject(); defer { try? FileManager.default.removeItem(at: dir) }
        let canonical = "Del\(UUID().uuidString.prefix(6))"
        try GlossaryStore.write(
            GlossaryDocument(terms: [term(canonical, ["variantone"], confidence: .declared)]),
            scope: .project, projectURL: dir
        )
        let e = editor(project: dir)
        let removed = try e.glossaryRemoveTerm(canonical: canonical, scope: .project)
        #expect(removed.map(\.canonical) == [canonical])
        #expect(try GlossaryStore.read(scope: .project, projectURL: dir).terms.isEmpty)
    }

    @Test func removeMissingTermReturnsEmpty() throws {
        let dir = try makeProject(); defer { try? FileManager.default.removeItem(at: dir) }
        let removed = try editor(project: dir).glossaryRemoveTerm(canonical: "absent", scope: .project)
        #expect(removed.isEmpty)
    }

    // promote moves scope: project → library, gone from project.
    @Test func promoteMovesTermUpToLibrary() throws {
        let dir = try makeProject(); defer { try? FileManager.default.removeItem(at: dir) }
        let canonical = "Prom\(UUID().uuidString.prefix(6))"
        try GlossaryStore.write(
            GlossaryDocument(terms: [term(canonical, ["variantone"], confidence: .asserted)]),
            scope: .project, projectURL: dir
        )
        let rows = try editor(project: dir).glossaryPromoteTerms(canonical: canonical, from: .project, to: .library)
        #expect(rows.map(\.canonical) == [canonical])
        #expect(try GlossaryStore.read(scope: .library, projectURL: dir).terms.contains { $0.canonical == canonical })
        #expect(!(try GlossaryStore.read(scope: .project, projectURL: dir).terms.contains { $0.canonical == canonical }))
    }

    // B2: the per-project engine override and routing preference survive a project save/load round trip.
    @Test func transcriptionModelRoundTripsThroughProjectFile() {
        let h = ToolHarness()
        h.editor.transcriptionLocalModel = .whisper
        h.editor.transcriptionPreference = .local
        let file = h.editor.projectFileSnapshot()

        let reloaded = EditorViewModel()
        reloaded.applyProjectFile(file)
        #expect(reloaded.transcriptionLocalModel == .whisper)
        #expect(reloaded.transcriptionPreference == .local)
    }
}
