// Materialisation, layering, boundary safety, dual-layer search, and re-index survival for the
// L1 glossary correction layer. refs feature/glossary

import Foundation
import Testing
@testable import PalmierPro

@Suite("Glossary", .isolatedGlossaryRoot)
struct GlossaryTests {
    private func corrector(_ terms: [GlossaryTerm]) -> GlossaryCorrector {
        GlossaryCorrector(terms: terms)
    }

    private func term(
        _ canonical: String,
        _ variants: [String],
        confidence: GlossaryConfidence = .declared
    ) -> GlossaryTerm {
        GlossaryTerm(canonical: canonical, variants: variants, provenance: "user", confidence: confidence)
    }

    private func result(text: String, segments: [String], words: [String]) -> TranscriptionResult {
        TranscriptionResult(
            text: text,
            language: "zh",
            words: words.enumerated().map { i, w in
                TranscriptionWord(text: w, start: Double(i), end: Double(i) + 1)
            },
            segments: segments.enumerated().map { i, s in
                TranscriptionSegment(text: s, start: Double(i * 5), end: Double(i * 5 + 5))
            }
        )
    }

    // MARK: - Materialisation

    @Test func replacesVariantInTextSegmentsAndWords() {
        let c = corrector([term("陈嬢嬢", ["陈娘娘"])])
        let raw = result(text: "去陈娘娘家", segments: ["去陈娘娘家吃饭"], words: ["去", "陈娘娘", "家"])
        let out = raw.applyingGlossary(c)
        #expect(out.text == "去陈嬢嬢家")
        #expect(out.segments[0].text == "去陈嬢嬢家吃饭")
        #expect(out.words[1].text == "陈嬢嬢")
    }

    @Test func rawInputIsUntouched() {
        let c = corrector([term("陈嬢嬢", ["陈娘娘"])])
        let raw = result(text: "陈娘娘", segments: ["陈娘娘"], words: ["陈娘娘"])
        _ = raw.applyingGlossary(c)
        #expect(raw.text == "陈娘娘")
        #expect(raw.segments[0].text == "陈娘娘")
        #expect(raw.words[0].text == "陈娘娘")
    }

    @Test func timingsAreNotShifted() {
        let c = corrector([term("陈嬢嬢", ["陈娘娘"])])
        let raw = result(text: "陈娘娘", segments: ["陈娘娘"], words: ["陈娘娘"])
        let out = raw.applyingGlossary(c)
        #expect(out.words[0].start == raw.words[0].start)
        #expect(out.words[0].end == raw.words[0].end)
        #expect(out.segments[0].start == raw.segments[0].start)
    }

    @Test func inferredTermsNeverAutoApply() {
        // Inferred terms are excluded from the store's auto-apply corrector.
        let store = GlossaryStore(layers: [
            .init(scope: .project, document: GlossaryDocument(terms: [
                term("陈嬢嬢", ["陈娘娘"], confidence: .inferred),
            ])),
        ], warnings: [])
        let out = result(text: "陈娘娘", segments: ["陈娘娘"], words: ["陈娘娘"]).applyingGlossary(store.corrector())
        #expect(out.text == "陈娘娘")
    }

    @Test func multiWordLatinVariantSpansTokens() {
        let c = corrector([term("black sesame", ["black sushi"])])
        let raw = TranscriptionResult(
            text: "I love black sushi rolls",
            language: "en",
            words: ["I", "love", "black", "sushi", "rolls"].enumerated().map {
                TranscriptionWord(text: $0.1, start: Double($0.0), end: Double($0.0) + 1)
            },
            segments: [TranscriptionSegment(text: "I love black sushi rolls", start: 0, end: 5)]
        )
        let out = raw.applyingGlossary(c)
        #expect(out.text == "I love black sesame rolls")
        #expect(out.segments[0].text == "I love black sesame rolls")
        // Canonical lands in the first token; the span tail is emptied so timings stay put.
        #expect(out.words[2].text == "black sesame")
        #expect(out.words[3].text == "")
        #expect(out.words[4].text == "rolls")
    }

    // MARK: - Layering

    @Test func laterLayerWinsPerCanonical() {
        let store = GlossaryStore(layers: [
            .init(scope: .global, document: GlossaryDocument(terms: [term("A", ["x"])])),
            .init(scope: .project, document: GlossaryDocument(terms: [term("A", ["y"])])),
        ], warnings: [])
        let merged = store.merged()
        #expect(merged.count == 1)
        #expect(merged[0].scope == .project)
        #expect(merged[0].term.variants == ["y"])
    }

    @Test func malformedFileWarnsAndProceedsUnbiased() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".palmier")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{ not json ".utf8).write(to: dir.appendingPathComponent("glossary.json"))

        let store = GlossaryStore.load(projectURL: dir)
        #expect(!store.warnings.isEmpty)
        #expect(store.corrector().isEmpty)
        let raw = result(text: "陈娘娘", segments: ["陈娘娘"], words: ["陈娘娘"])
        #expect(raw.applyingGlossary(store.corrector()).text == "陈娘娘")
    }

    // MARK: - Boundary safety (§5.4)

    @Test func shortCJKVariantRejectedByValidator() {
        // 师→狮 with variant 师 (1 CJK char) must be rejected by the validator.
        let result = GlossaryValidation.sanitize(term("狮", ["师"]), otherCanonicals: [])
        #expect(result.term.variants.isEmpty)
        #expect(!result.rejectedVariants.isEmpty)
    }

    @Test func handAuthoredShortVariantIsSanitizedAtReadTime() throws {
        // A malicious/hand-authored glossary.json bypasses glossary_add's validation entirely,
        // so the STORE read path must drop 师 (1 CJK char) before building the corrector —
        // otherwise correct("我的老师说") would corrupt 老师 into 老狮.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".palmier")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"version":1,"terms":[{"canonical":"狮","variants":["师"],"provenance":"user","confidence":"declared"}]}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("glossary.json"))

        let store = GlossaryStore.load(projectURL: dir)
        #expect(store.corrector().correct("我的老师说") == "我的老师说")
        // The drop is surfaced so a hand-author can see why the entry didn't apply.
        #expect(store.allWarnings().contains { $0.contains("师") && $0.contains("狮") })
        #expect(store.autoApplyTerms.first?.variants.isEmpty == true)
    }

    @Test func longestMatchFirstAcrossVariants() {
        // Both 娘娘 and 陈娘娘 are variants; the longer one must win inside 陈娘娘.
        let c = corrector([
            term("陈嬢嬢", ["陈娘娘"]),
            term("娘娘庙", ["娘娘"]),
        ])
        #expect(c.correct("去陈娘娘家") == "去陈嬢嬢家")
    }

    @Test func latinVariantRespectsWordBoundaries() {
        let c = corrector([term("Kubernetes", ["kubernetis"])])
        #expect(c.correct("we use kubernetis here") == "we use Kubernetes here")
        // Must not fire inside a longer word.
        #expect(c.correct("kubernetisation") == "kubernetisation")
    }

    @Test func shortLatinVariantRejected() {
        let r = GlossaryValidation.sanitize(term("AI", ["ai"]), otherCanonicals: [])
        #expect(r.term.variants.isEmpty)  // "ai" is 2 Latin chars, below the minimum of 3
    }

    @Test func collisionWithAnotherCanonicalWarns() {
        let r = GlossaryValidation.sanitize(
            term("Canonical", ["OtherName"]), otherCanonicals: ["OtherName"]
        )
        #expect(r.term.variants == ["OtherName"])  // kept, but warned
        #expect(r.warnings.contains { $0.contains("collides") })
    }

    // MARK: - Store round-trip (the add/remove/list file layer)

    @Test func writeThenLoadAppliesCorrection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".palmier")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var doc = try GlossaryStore.read(scope: .project, projectURL: dir)
        #expect(doc.terms.isEmpty)
        doc.terms.append(term("陈嬢嬢", ["陈娘娘"]))
        try GlossaryStore.write(doc, scope: .project, projectURL: dir)

        let reloaded = GlossaryStore.load(projectURL: dir)
        #expect(reloaded.corrector().correct("陈娘娘") == "陈嬢嬢")

        // Removing it clears the correction.
        var after = try GlossaryStore.read(scope: .project, projectURL: dir)
        after.terms.removeAll { $0.canonical == "陈嬢嬢" }
        try GlossaryStore.write(after, scope: .project, projectURL: dir)
        #expect(GlossaryStore.load(projectURL: dir).corrector().correct("陈娘娘") == "陈娘娘")
    }

    @Test func projectScopeUnavailableWithoutProject() {
        #expect(throws: GlossaryError.self) {
            try GlossaryStore.read(scope: .project, projectURL: nil)
        }
    }

    // MARK: - Fingerprint

    @Test func biasFingerprintIsStableAndSensitive() {
        // Variants must clear the §5.4 length floor or read-time sanitization strips them.
        let a = GlossaryStore(layers: [.init(scope: .project, document: GlossaryDocument(terms: [term("Xterm", ["variantone"])]))], warnings: [])
        let b = GlossaryStore(layers: [.init(scope: .project, document: GlossaryDocument(terms: [term("Xterm", ["variantone"])]))], warnings: [])
        let c = GlossaryStore(layers: [.init(scope: .project, document: GlossaryDocument(terms: [term("Xterm", ["varianttwo"])]))], warnings: [])
        #expect(a.biasFingerprint() == b.biasFingerprint())
        #expect(a.biasFingerprint() != c.biasFingerprint())
        #expect(a.hotwordTerms() == ["Xterm"])
    }

    // MARK: - Mixed-script variant boundaries (B3)

    @Test func mixedScriptVariantRespectsLatinEdge() {
        // "AI技术" starts with a Latin edge; it must correct 我用AI技术 but never fire mid-word in
        // OpenAI技术 (which would corrupt it to Open人工智能).
        let c = corrector([term("人工智能", ["AI技术"])])
        #expect(c.correct("我用AI技术") == "我用人工智能")
        #expect(c.correct("OpenAI技术") == "OpenAI技术")
    }

    @Test func mixedScriptVariantLeadingDigitEdge() {
        // "5G网络" leads with a digit (a Latin word char); H5G网络 must not match mid-token.
        let c = corrector([term("五G网络", ["5G网络"])])
        #expect(c.correct("用5G网络") == "用五G网络")
        #expect(c.correct("H5G网络") == "H5G网络")
    }

    @Test func mixedScriptVariantTrailingLatinEdge() {
        // "手机iPhone" ends on a Latin edge; must not fire inside 手机iPhones.
        let c = corrector([term("手机苹果", ["手机iPhone"])])
        #expect(c.correct("买手机iPhone吧") == "买手机苹果吧")
        #expect(c.correct("手机iPhones") == "手机iPhones")
    }

    @Test func pureCJKAndPureLatinUnaffectedByEdgeRule() {
        let cjk = corrector([term("嬢嬢", ["娘娘"])])
        #expect(cjk.correct("陈娘娘家") == "陈嬢嬢家")
        let latin = corrector([term("Kubernetes", ["kubernetis"])])
        #expect(latin.correct("kubernetisation") == "kubernetisation")
    }

    // MARK: - Whitespace-only variants + tie-break (B4)

    @Test func whitespaceOnlyVariantRejectedBySanitize() {
        let r = GlossaryValidation.sanitize(term("canonical", [" "]), otherCanonicals: [])
        #expect(r.term.variants.isEmpty)
        #expect(r.rejectedVariants.contains(" "))
        #expect(r.warnings.contains { $0.contains("whitespace-only") })
    }

    @Test func whitespaceOnlyVariantNeverReplacesEmptyTokens() {
        // A blank variant must not reach the corrector and blank out real tokens.
        let c = corrector([term("canonical", [" "])])
        #expect(c.correctWordSpans(["a", "b"]) == ["a", "b"])
    }

    @Test func sharedVariantResolvesDeterministically() {
        // Two terms sharing the variant "xyz" resolve to the lexicographically-smaller canonical,
        // regardless of construction order.
        let ab = corrector([term("AAA", ["xyzxyz"]), term("BBB", ["xyzxyz"])])
        let ba = corrector([term("BBB", ["xyzxyz"]), term("AAA", ["xyzxyz"])])
        #expect(ab.correct("xyzxyz") == "AAA")
        #expect(ba.correct("xyzxyz") == "AAA")
    }

    // MARK: - Promotion planner (B1c)

    private func doc(_ terms: [GlossaryTerm]) -> GlossaryDocument { GlossaryDocument(terms: terms) }

    @Test func planPromotesSingleTermAndRemovesFromSource() {
        let plan = GlossaryPromotion.plan(
            from: doc([term("嬢嬢", ["娘娘"]), term("狮", ["师傅"])]),
            to: doc([]), fromWinsCollision: true, canonical: "嬢嬢", confidence: nil
        )
        #expect(plan.to.terms.map(\.canonical) == ["嬢嬢"])
        #expect(plan.from.terms.map(\.canonical) == ["狮"])
        #expect(plan.rows == [.init(canonical: "嬢嬢", collision: nil)])
    }

    @Test func planPromotesAllTerms() {
        let plan = GlossaryPromotion.plan(
            from: doc([term("A", ["aa"]), term("B", ["bb"])]),
            to: doc([]), fromWinsCollision: true, canonical: nil, confidence: nil
        )
        #expect(Set(plan.to.terms.map(\.canonical)) == ["A", "B"])
        #expect(plan.from.terms.isEmpty)
        #expect(plan.rows.count == 2)
    }

    @Test func planConfidenceFilterSelectsSubset() {
        let plan = GlossaryPromotion.plan(
            from: doc([term("A", ["aa"], confidence: .asserted), term("B", ["bb"], confidence: .declared)]),
            to: doc([]), fromWinsCollision: true, canonical: "all", confidence: .asserted
        )
        #expect(plan.to.terms.map(\.canonical) == ["A"])
        #expect(plan.from.terms.map(\.canonical) == ["B"])
    }

    @Test func planCollisionHigherScopeWins() {
        // Promoted term from the higher-precedence scope overwrites the destination entry.
        let win = GlossaryPromotion.plan(
            from: doc([term("A", ["fresh"])]), to: doc([term("A", ["stale"])]),
            fromWinsCollision: true, canonical: "A", confidence: nil
        )
        #expect(win.to.terms.map(\.variants) == [["fresh"]])
        #expect(win.rows == [.init(canonical: "A", collision: .overwrote)])
        // When the destination is the higher scope, its entry is kept and the source copy removed.
        let keep = GlossaryPromotion.plan(
            from: doc([term("A", ["fresh"])]), to: doc([term("A", ["stale"])]),
            fromWinsCollision: false, canonical: "A", confidence: nil
        )
        #expect(keep.to.terms.map(\.variants) == [["stale"]])
        #expect(keep.from.terms.isEmpty)
        #expect(keep.rows == [.init(canonical: "A", collision: .kept)])
    }
}

/// Tool-level glossary_promote / glossary_list behaviour that needs a live ToolExecutor.
@Suite("Glossary tools", .isolatedGlossaryRoot)
@MainActor
struct GlossaryToolTests {
    private func makeProject() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gloss-tool-\(UUID().uuidString).palmier", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func term(_ canonical: String, _ variants: [String], confidence: GlossaryConfidence) -> GlossaryTerm {
        GlossaryTerm(canonical: canonical, variants: variants, provenance: "user", confidence: confidence)
    }

    @Test func listNotesAssertedProjectScopeTerms() async throws {
        let dir = try makeProject()
        defer { try? FileManager.default.removeItem(at: dir) }
        let canonical = "Prj\(UUID().uuidString.prefix(6))"
        try GlossaryStore.write(
            GlossaryDocument(terms: [term(canonical, ["variantone"], confidence: .asserted)]),
            scope: .project, projectURL: dir
        )
        let h = ToolHarness()
        h.editor.projectURL = dir

        let payload = try await h.runOK("glossary_list") as? [String: Any]
        let note = payload?["note"] as? String
        #expect(note?.contains("asserted project-scope term") == true)
        #expect(note?.contains("glossary_promote") == true)
    }

    @Test func promoteMovesTermFromProjectToLibrary() async throws {
        let dir = try makeProject()
        defer { try? FileManager.default.removeItem(at: dir) }
        let canonical = "Lib\(UUID().uuidString.prefix(6))"
        try GlossaryStore.write(
            GlossaryDocument(terms: [term(canonical, ["variantone"], confidence: .asserted)]),
            scope: .project, projectURL: dir
        )
        let h = ToolHarness()
        h.editor.projectURL = dir

        let payload = try await h.runOK("glossary_promote", args: ["canonical": canonical]) as? [String: Any]
        #expect(payload?["count"] as? Int == 1)
        #expect(payload?["toScope"] as? String == "library")

        // Landed in library (isolated temp root via .isolatedGlossaryRoot), gone from project.
        let lib = try GlossaryStore.read(scope: .library, projectURL: dir)
        #expect(lib.terms.contains { $0.canonical == canonical })
        let project = try GlossaryStore.read(scope: .project, projectURL: dir)
        #expect(!project.terms.contains { $0.canonical == canonical })
    }
}
