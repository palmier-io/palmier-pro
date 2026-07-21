import Foundation
import Testing
@testable import PalmierPro

@Suite("CaptionStyle")
struct CaptionStyleTests {
    // MARK: - Filler classification & planning

    @Test func removeAlwaysStripsSafeFillersKeepsNeverRemove() {
        let policy = FillerPolicy(profile: .builtInDefault)
        let actions = policy.plan(words: ["呃", "哎", "um", "然后", "oh", "hello"])
        let byToken = Dictionary(uniqueKeysWithValues: actions.map { ($0.token, $0.decision) })
        #expect(byToken["呃"] == .remove)
        #expect(byToken["哎"] == .remove)
        #expect(byToken["um"] == .remove)
        #expect(byToken["然后"] == .keep)
        #expect(byToken["oh"] == .keep)
        #expect(byToken["hello"] == .keep)
    }

    @Test func caseByCaseIsFlaggedNeverRemoved() {
        let policy = FillerPolicy(profile: .builtInDefault)
        #expect(policy.classify("啊") == .caseByCase)
        let actions = policy.plan(words: ["啊", "我们", "走"])
        let ah = actions.first { $0.token == "啊" }
        #expect(ah?.decision == .flag)
        #expect(actions.allSatisfy { !($0.token == "啊" && $0.decision == .remove) })
        #expect(!actions.contains { $0.decision == .remove })
    }

    @Test func protectedPhraseSurvivesEveryPass() {
        var profile = CaptionStyleProfile.builtInDefault
        profile.protectedPhrases = ["兄弟牛逼"]
        let policy = FillerPolicy(profile: profile)

        let single = policy.plan(words: ["兄弟牛逼"])
        #expect(single.allSatisfy { $0.decision == .keep })

        // Repeated as comic timing — still never removed or deduped.
        let repeated = policy.plan(words: ["兄弟牛逼", "兄弟牛逼", "兄弟牛逼"])
        #expect(repeated.allSatisfy { $0.decision == .keep })
        #expect(!repeated.contains { $0.decision == .removeDuplicate })
    }

    @Test func multiWordProtectedPhraseOverridesFillerClassification() {
        var profile = CaptionStyleProfile.builtInDefault
        profile.protectedPhrases = ["you know"]
        let policy = FillerPolicy(profile: profile)
        let actions = policy.plan(words: ["you", "know", "um"])
        #expect(actions[0].decision == .keep)
        #expect(actions[0].reason == "protectedPhrase")
        #expect(actions[1].decision == .keep)
        #expect(actions[2].decision == .remove)
    }

    @Test func cjkReduplicationIsNeverDuplicateRemovable() {
        let policy = FillerPolicy(profile: .builtInDefault)
        for tokens in [["存", "存", "钱"], ["试", "试", "看"]] {
            let actions = policy.plan(words: tokens)
            #expect(!actions.contains { $0.decision == .removeDuplicate })
            #expect(!actions.contains { $0.decision == .remove })
        }
    }

    @Test func comicRepetitionIsPreserved() {
        let policy = FillerPolicy(profile: .builtInDefault)
        let actions = policy.plan(words: ["True,", "true,", "true,", "true"])
        #expect(actions.allSatisfy { $0.decision == .keep })
        #expect(!actions.contains { $0.decision == .removeDuplicate })
    }

    @Test func unguardedStutterIsDuplicateRemovable() {
        var profile = CaptionStyleProfile.builtInDefault
        profile.fillers.neverDedupe = .init(cjkReduplication: true, comicRepetition: true)
        let policy = FillerPolicy(profile: profile)
        // A two-token English stutter is not comic (needs 3+) and not CJK — removable.
        let actions = policy.plan(words: ["the", "the", "cat"])
        #expect(actions[0].decision == .keep)
        #expect(actions[1].decision == .removeDuplicate)
        #expect(actions[2].decision == .keep)
    }

    @Test func nonFillerWordsPassThroughVerbatim() {
        let policy = FillerPolicy(profile: .builtInDefault)
        let actions = policy.plan(words: ["local", "citizens"])
        #expect(actions.allSatisfy { $0.decision == .keep })
        #expect(actions.map(\.token) == ["local", "citizens"])
    }

    // MARK: - Phrase stripping (add_captions removeAlways path)

    @Test func strippingRemovesOnlyRemoveAlwaysTokens() {
        let policy = FillerPolicy(profile: .builtInDefault)
        let phrase = CaptionBuilder.Phrase(
            text: "um hello uh there",
            start: 0,
            end: 1.0,
            words: [
                .init(text: "um", start: 0, end: 0.2),
                .init(text: "hello", start: 0.2, end: 0.5),
                .init(text: "uh", start: 0.5, end: 0.6),
                .init(text: "there", start: 0.6, end: 1.0),
            ]
        )
        let stripped = policy.strippingRemoveAlways(phrase)
        #expect(stripped?.text == "hello there")
        #expect(stripped?.words.map(\.text) == ["hello", "there"])
        #expect(stripped?.start == 0.2)
        #expect(stripped?.end == 1.0)
    }

    @Test func strippingLeavesNonFillerContentUntouched() {
        let policy = FillerPolicy(profile: .builtInDefault)
        let phrase = CaptionBuilder.Phrase(text: "local citizens", start: 0, end: 1)
        let stripped = policy.strippingRemoveAlways(phrase)
        #expect(stripped?.text == "local citizens")
    }

    // MARK: - Layered merge

    @Test func projectLayerOverridesGlobalPerProvidedKey() {
        var global = CaptionStyleProfilePartial()
        global.removeAlways = ["um"]
        global.typography = .init(fontName: "Helvetica", fontSize: 40, color: nil, outline: nil, shadow: nil, position: nil, maxWords: nil)

        var project = CaptionStyleProfilePartial()
        project.removeAlways = ["呃"]
        project.typography = .init(fontName: nil, fontSize: 60, color: nil, outline: nil, shadow: nil, position: nil, maxWords: nil)

        let base = CaptionStyleProfilePartial(from: .builtInDefault)
        let resolved = base.overlaid(by: global).overlaid(by: project).resolved()

        // Provided keys replace wholesale...
        #expect(resolved.fillers.removeAlways == ["呃"])
        #expect(resolved.typography.fontSize == 60)
        // ...absent typography keys inherit the earlier layer.
        #expect(resolved.typography.fontName == "Helvetica")
    }

    // MARK: - File-based resolution

    @Test func resolveReadsProjectSidecar() throws {
        let pkg = try makeTempPackage()
        defer { try? FileManager.default.removeItem(at: pkg) }
        let json = #"{"version":1,"protectedPhrases":["兄弟牛逼"],"fillers":{"removeAlways":["嗯嗯"]}}"#
        try json.data(using: .utf8)!.write(to: pkg.appendingPathComponent(Project.captionStyleFilename))

        let resolved = CaptionStyleStore.resolve(projectPackageURL: pkg)
        #expect(resolved.profile.protectedPhrases.contains("兄弟牛逼"))
        #expect(resolved.profile.fillers.removeAlways == ["嗯嗯"])
        #expect(resolved.origins.contains { $0.scope == .project && $0.status == .loaded })
    }

    @Test func malformedProjectSidecarFallsBackWithWarning() throws {
        let pkg = try makeTempPackage()
        defer { try? FileManager.default.removeItem(at: pkg) }
        try "{ this is not json".data(using: .utf8)!.write(to: pkg.appendingPathComponent(Project.captionStyleFilename))

        let resolved = CaptionStyleStore.resolve(projectPackageURL: pkg)
        // Never crashes; falls back to a usable profile with default dedupe guards.
        #expect(resolved.profile.fillers.neverDedupe.cjkReduplication)
        #expect(resolved.origins.contains { $0.scope == .project && $0.status == .malformed })
        #expect(resolved.warnings.contains { $0.contains(pkg.path) })
    }

    @Test func missingProjectSidecarUsesDefaults() throws {
        let pkg = try makeTempPackage()
        defer { try? FileManager.default.removeItem(at: pkg) }
        let resolved = CaptionStyleStore.resolve(projectPackageURL: pkg)
        #expect(resolved.origins.contains { $0.scope == .project && $0.status == .missing })
        #expect(resolved.profile.version == 1)
    }

    // MARK: - Typography application

    @MainActor
    @Test func profileTypographyFillsCaptionStyle() {
        let typography = CaptionStyleProfile.Typography(
            fontName: "Georgia", fontSize: 72, color: "#FF0000",
            outline: true, shadow: false, position: nil, maxWords: nil
        )
        var style = TextStyle(fontSize: AppTheme.Caption.defaultFontSize)
        ToolExecutor.applyProfileTypography(typography, to: &style)
        #expect(style.fontName == "Georgia")
        #expect(style.fontSize == 72)
        #expect(style.color == TextStyle.RGBA(r: 1, g: 0, b: 0, a: 1))
        #expect(style.border.enabled == true)
        #expect(style.shadow.enabled == false)
    }

    @MainActor
    @Test func nilTypographyKeysLeaveDefaultsIntact() {
        let typography = CaptionStyleProfile.Typography(fontSize: 96)
        var style = TextStyle(fontSize: AppTheme.Caption.defaultFontSize)
        let originalFont = style.fontName
        ToolExecutor.applyProfileTypography(typography, to: &style)
        #expect(style.fontSize == 96)
        #expect(style.fontName == originalFont)
    }

    // MARK: - Helpers

    private func makeTempPackage() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("caption-style-test-\(UUID().uuidString).palmier", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// Review regressions: a partial explicit style must not discard the rest of the profile, and
// removeAlways must match single-character CJK fillers inside unsegmented phrase text.
@Suite struct CaptionStyleReviewRegressionTests {
    @Test func cjkFillerStrippedFromUnsegmentedPhrase() {
        var profile = CaptionStyleProfile.builtInDefault
        profile.fillers.removeAlways = ["呃"]
        let policy = FillerPolicy(profile: profile)
        let phrase = CaptionBuilder.Phrase(text: "呃你好 ok", start: 0, end: 1)
        let stripped = policy.strippingRemoveAlways(phrase)
        #expect(stripped?.text == "你好 ok")
    }

    @Test func fallbackTokensSplitCJKKeepLatinRuns() {
        #expect(FillerPolicy.fallbackTokens("呃你好 hello there") == ["呃", "你", "好", "hello", "there"])
        #expect(FillerPolicy.joinTokens(["你", "好", "hello"]) == "你好 hello")
    }
}

// Round-2 review: the timed path must behave like the fallback path — CJK fillers matched inside
// word blobs, protected phrases matched across per-char streams, no spaces introduced into CJK.
@Suite struct FillerPolicyTimedPathTests {
    private func timedPhrase(_ words: [(String, Double, Double)]) -> CaptionBuilder.Phrase {
        let spans = words.map { CaptionBuilder.WordSpan(text: $0.0, start: $0.1, end: $0.2) }
        return CaptionBuilder.Phrase(text: words.map(\.0).joined(), start: words.first!.1, end: words.last!.2, words: spans)
    }

    @Test func timedCJKFillerBlobIsRemoved() {
        var profile = CaptionStyleProfile.builtInDefault
        profile.fillers.removeAlways = ["呃"]
        let policy = FillerPolicy(profile: profile)
        let phrase = timedPhrase([("呃", 0, 0.3), ("你", 0.3, 0.6), ("好", 0.6, 0.9)])
        let stripped = policy.strippingRemoveAlways(phrase)
        #expect(stripped?.text == "你好")
        #expect(stripped?.words.map(\.text) == ["你", "好"])
    }

    @Test func timedCJKKeepsNoSpuriousSpaces() {
        let policy = FillerPolicy(profile: .builtInDefault)
        let phrase = timedPhrase([("你", 0, 0.3), ("好", 0.3, 0.6)])
        let stripped = policy.strippingRemoveAlways(phrase)
        #expect(stripped?.text == "你好")
    }

    @Test func protectedPhraseMatchesPerCharStream() {
        var profile = CaptionStyleProfile.builtInDefault
        profile.protectedPhrases = ["兄弟牛逼"]
        profile.fillers.removeAlways = ["逼"]
        let policy = FillerPolicy(profile: profile)
        let phrase = CaptionBuilder.Phrase(text: "兄弟牛逼", start: 0, end: 1)
        #expect(policy.strippingRemoveAlways(phrase)?.text == "兄弟牛逼")
    }
}

// Round-3: a multi-character CJK removeAlways entry (one profile string, e.g. 嗯嗯) must strip on
// the timed path, where the stream is flattened to per-character tokens.
@Suite struct FillerPolicyMultiCharEntryTests {
    @Test func multiCharCJKEntryStripsOnTimedPath() {
        var profile = CaptionStyleProfile.builtInDefault
        profile.fillers.removeAlways = ["嗯嗯"]
        let policy = FillerPolicy(profile: profile)
        let spans = [CaptionBuilder.WordSpan(text: "嗯嗯", start: 0, end: 0.4),
                     CaptionBuilder.WordSpan(text: "好", start: 0.4, end: 0.8)]
        let phrase = CaptionBuilder.Phrase(text: "嗯嗯好", start: 0, end: 0.8, words: spans)
        let stripped = policy.strippingRemoveAlways(phrase)
        #expect(stripped?.text == "好")
        #expect(stripped?.words.map(\.text) == ["好"])
    }
}
