import Foundation
import Testing
@testable import PalmierPro

private struct StubCompleter: LintCompleter {
    let response: String
    func complete(system: String, user: String) async throws -> String { response }
}

private struct FailingCompleter: LintCompleter {
    struct Boom: Error {}
    func complete(system: String, user: String) async throws -> String { throw Boom() }
}

/// Returns fixed words for any span — stands in for a cached transcript so the post-edit caption
/// resync rebuilds to the same text instead of clearing it (production always has a transcript).
private struct FixedWordSource: CaptionWordSource {
    let words: [WordTiming]
    func audibleWords(in range: Range<Int>) -> [WordTiming] { words }
    func uncachedRefs(in range: Range<Int>) -> [String] { [] }
}

// MARK: - Core linter (pure, no editor)

@Suite struct CaptionLinterTests {
    private func window(_ id: String, _ text: String, start: Int = 100, end: Int = 150, prev: String? = nil, next: String? = nil) -> LintWindow {
        LintWindow(clipId: id, startFrame: start, endFrame: end, text: text, prevText: prev, nextText: next)
    }

    @Test func flagsNearSoundSubstitutionWithContextAndFrames() async throws {
        let w = window("c1", "好久没有开照片了", start: 100, end: 150, next: "今天来拍个 vlog")
        let stub = StubCompleter(response: """
        [{"clipId":"c1","original":"开照片","suggestion":"拍照片","reason":"near-sound; context is shooting a vlog","confidence":0.8}]
        """)
        let flags = try await CaptionLinter.flag(windows: [w], exclusions: LintExclusions(terms: []), completer: stub)
        #expect(flags.count == 1)
        let f = try #require(flags.first)
        #expect(f.clipId == "c1")
        #expect(f.original == "开照片")
        #expect(f.suggestion == "拍照片")
        #expect(f.startFrame == 100 && f.endFrame == 150)
        #expect(f.confidence == 0.8)
        #expect(f.reason.contains("near-sound"))
    }

    @Test func fillersAndGlossaryTermsAreNotFlagged() async throws {
        let excl = LintExclusions(terms: ["呃", "小明"])  // filler + a glossary variant
        // A correction whose change lands on an excluded term is suppressed.
        #expect(excl.excludesChange(original: "呃", suggestion: "啊"))
        #expect(excl.excludesChange(original: "小明", suggestion: "小名"))
        #expect(!excl.excludesChange(original: "拍照片", suggestion: "开照片"))

        let w = window("c1", "呃 小明 去 拍照片")
        let stub = StubCompleter(response: """
        [{"clipId":"c1","original":"呃","suggestion":"啊","reason":"x","confidence":0.9},
         {"clipId":"c1","original":"小明","suggestion":"小名","reason":"x","confidence":0.9}]
        """)
        let flags = try await CaptionLinter.flag(windows: [w], exclusions: excl, completer: stub)
        #expect(flags.isEmpty)
    }

    // F1 regression — mask only the CHANGED tokens, not the whole flagged span.

    @Test func excludedTermInUnchangedTokensDoesNotSuppress() async throws {
        // 视频 is a glossary canonical; the fix changes 开→拍, leaving 视频 untouched → still flagged.
        let excl = LintExclusions(terms: ["视频"])
        let w = window("c1", "好久没有开照片了", next: "今天来拍")
        let stub = StubCompleter(response: """
        [{"clipId":"c1","original":"开照片","suggestion":"拍照片","reason":"near-sound","confidence":0.8}]
        """)
        #expect(!excl.excludesChange(original: "开照片", suggestion: "拍照片"))
        let flags = try await CaptionLinter.flag(windows: [w], exclusions: excl, completer: stub)
        #expect(flags.count == 1)
        #expect(flags.first?.suggestion == "拍照片")
    }

    @Test func adjacentFillerDoesNotSuppress() async throws {
        // 呃 is a filler sitting next to the changed word — the change is at 开, so it stays flagged.
        let excl = LintExclusions(terms: ["呃"])
        let w = window("c1", "呃开照片了")
        let stub = StubCompleter(response: """
        [{"clipId":"c1","original":"呃开照片","suggestion":"呃拍照片","reason":"near-sound","confidence":0.8}]
        """)
        #expect(!excl.excludesChange(original: "呃开照片", suggestion: "呃拍照片"))
        let flags = try await CaptionLinter.flag(windows: [w], exclusions: excl, completer: stub)
        #expect(flags.count == 1)
    }

    @Test func changeThatEditsAnExcludedTermIsDropped() async throws {
        // The suggestion tries to "fix" the excluded glossary term itself → suppressed.
        let excl = LintExclusions(terms: ["视频"])
        let w = window("c1", "我在看视频呢")
        let stub = StubCompleter(response: """
        [{"clipId":"c1","original":"视频","suggestion":"视屏","reason":"x","confidence":0.9}]
        """)
        #expect(excl.excludesChange(original: "视频", suggestion: "视屏"))
        let flags = try await CaptionLinter.flag(windows: [w], exclusions: excl, completer: stub)
        #expect(flags.isEmpty)
    }

    @Test func contextModeReturnsJudgeableWindowsWithExclusions() {
        let excl = LintExclusions(terms: ["呃"])
        let w = window("c1", "呃 我们开始吧", start: 30, end: 90, prev: "上一句", next: "下一句")
        let segs = CaptionLinter.contextSegments(windows: [w], exclusions: excl)
        #expect(segs.count == 1)
        let s = segs[0]
        #expect(s["clipId"] as? String == "c1")
        #expect(s["frameRange"] as? [Int] == [30, 90])
        #expect(s["text"] as? String == "呃 我们开始吧")
        #expect(s["prevText"] as? String == "上一句")
        #expect(s["nextText"] as? String == "下一句")
        #expect((s["exclusions"] as? [String])?.contains("呃") == true)
    }

    @Test func partitionGatesAutoApply() {
        let hi = LintCandidate(clipId: "c1", startFrame: 0, endFrame: 10, original: "a", suggestion: "b", reason: "", confidence: 0.8)
        let lo = LintCandidate(clipId: "c2", startFrame: 0, endFrame: 10, original: "c", suggestion: "d", reason: "", confidence: 0.4)

        // No threshold → nothing is applied; everything stays a flag.
        let none = CaptionLinter.partition([hi, lo], threshold: nil)
        #expect(none.apply.isEmpty)
        #expect(none.flag.count == 2)

        // Threshold splits at/above vs below.
        let split = CaptionLinter.partition([hi, lo], threshold: 0.7)
        #expect(split.apply.map(\.clipId) == ["c1"])
        #expect(split.flag.map(\.clipId) == ["c2"])
    }

    @Test func dropsFlagWhoseOriginalIsAbsentFromText() async throws {
        let w = window("c1", "好久没有开照片了")
        let stub = StubCompleter(response: """
        [{"clipId":"c1","original":"苹果","suggestion":"香蕉","reason":"x","confidence":0.9}]
        """)
        let flags = try await CaptionLinter.flag(windows: [w], exclusions: LintExclusions(terms: []), completer: stub)
        #expect(flags.isEmpty)
    }

    @Test func toolIsRegisteredAndDiscoverable() {
        #expect(ToolName(rawValue: "caption_lint") == .captionLint)
        #expect(ToolDefinitions.all.contains { $0.name == .captionLint })
    }
}

// MARK: - Tool wiring (editor + injected completer)

@MainActor
@Suite(.isolatedGlossaryRoot, .hermeticCaptionStyle) struct CaptionLintToolTests {
    private func spec(_ text: String, start: Int, duration: Int, group: String) -> EditorViewModel.TextClipSpec {
        var s = EditorViewModel.TextClipSpec(
            trackIndex: 0, startFrame: start, durationFrames: duration,
            content: text, style: TextStyle(), transform: nil
        )
        s.captionGroupId = group
        return s
    }

    private func editorWithCaptions(_ texts: [(String, Int, Int)]) -> EditorViewModel {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack()])
        _ = e.placeTextClips(texts.map { spec($0.0, start: $0.1, duration: $0.2, group: "g1") })
        return e
    }

    private func clipId(_ e: EditorViewModel, text: String) -> String {
        e.timeline.tracks.flatMap(\.clips).first { $0.textContent == text }!.id
    }

    private func body(_ result: ToolResult) -> [String: Any] {
        guard case .text(let s)? = result.content.first,
              let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    /// Bind a UNIQUE temp library for the body so parallel writer tests don't share the suite's library.
    private func withFreshLibrary<T>(_ body: () throws -> T) rethrows -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cs-lib-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try CaptionStyleStore.$libraryDirectoryOverride.withValue(dir) { try body() }
    }

    private func withFreshLibrary<T>(_ body: () async throws -> T) async rethrows -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cs-lib-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await CaptionStyleStore.$libraryDirectoryOverride.withValue(dir) { try await body() }
    }

    @Test func flagsModeSurfacesButDoesNotApply() async throws {
        let e = editorWithCaptions([("好久没有开照片了", 100, 50), ("今天来拍个 vlog", 150, 50)])
        let target = clipId(e, text: "好久没有开照片了")
        let stub = StubCompleter(response: """
        [{"clipId":"\(target)","original":"开照片","suggestion":"拍照片","reason":"near-sound","confidence":0.8}]
        """)
        let exec = ToolExecutor(editor: e)
        let result = try await exec.captionLint(e, ["mode": "flags"], completer: stub)
        let out = body(result)

        let flags = out["flags"] as? [[String: Any]] ?? []
        #expect(flags.count == 1)
        #expect(flags.first?["original"] as? String == "开照片")
        #expect(flags.first?["frameRange"] as? [Int] == [100, 150])
        #expect((out["applied"] as? [[String: Any]])?.isEmpty ?? true)
        // Nothing changed without a threshold.
        #expect(e.timeline.tracks.flatMap(\.clips).first { $0.id == target }?.textContent == "好久没有开照片了")
    }

    @Test func autoApplyAboveThresholdRewritesTheClip() async throws {
        let e = editorWithCaptions([("好久没有开照片了", 100, 50)])
        let target = clipId(e, text: "好久没有开照片了")
        let stub = StubCompleter(response: """
        [{"clipId":"\(target)","original":"开照片","suggestion":"拍照片","reason":"near-sound","confidence":0.8}]
        """)
        // A cached transcript stand-in so the post-promotion resync rebuilds the corrected caption
        // rather than clearing it (the auto-applied edit now promotes into the glossary — which the
        // suite's .isolatedGlossaryRoot trait keeps off the real user library).
        e.captionWordSourceProvider = { _ in
            FixedWordSource(words: [WordTiming(text: "好久没有拍照片了", startFrame: 100, endFrame: 150)])
        }
        let exec = ToolExecutor(editor: e)
        let result = try await exec.captionLint(e, ["mode": "flags", "autoApplyThreshold": 0.7], completer: stub)
        let out = body(result)

        let applied = out["applied"] as? [[String: Any]] ?? []
        #expect(applied.count == 1)
        #expect(applied.first?["suggestion"] as? String == "拍照片")
        #expect((out["flags"] as? [[String: Any]])?.isEmpty ?? true)
        #expect(e.timeline.tracks.flatMap(\.clips).first { $0.id == target }?.textContent == "好久没有拍照片了")
    }

    @Test func belowThresholdStaysFlagged() async throws {
        let e = editorWithCaptions([("好久没有开照片了", 100, 50)])
        let target = clipId(e, text: "好久没有开照片了")
        let stub = StubCompleter(response: """
        [{"clipId":"\(target)","original":"开照片","suggestion":"拍照片","reason":"near-sound","confidence":0.5}]
        """)
        let exec = ToolExecutor(editor: e)
        let out = body(try await exec.captionLint(e, ["mode": "flags", "autoApplyThreshold": 0.9], completer: stub))
        #expect((out["flags"] as? [[String: Any]])?.count == 1)
        #expect((out["applied"] as? [[String: Any]])?.isEmpty ?? true)
        #expect(e.timeline.tracks.flatMap(\.clips).first { $0.id == target }?.textContent == "好久没有开照片了")
    }

    @Test func builtInFillerIsExcludedThroughTheTool() async throws {
        let e = editorWithCaptions([("呃 我们开始吧", 0, 40)])
        let target = clipId(e, text: "呃 我们开始吧")
        let stub = StubCompleter(response: """
        [{"clipId":"\(target)","original":"呃","suggestion":"啊","reason":"x","confidence":0.9}]
        """)
        let exec = ToolExecutor(editor: e)
        let out = body(try await exec.captionLint(e, ["mode": "flags"], completer: stub))
        #expect((out["flags"] as? [[String: Any]])?.isEmpty ?? true)
        #expect((out["skippedExclusions"] as? Int ?? 0) >= 1)
    }

    @Test func contextModeMakesNoModelCall() async throws {
        let e = editorWithCaptions([("好久没有开照片了", 100, 50)])
        let exec = ToolExecutor(editor: e)
        // A failing completer proves context mode never calls it.
        let out = body(try await exec.captionLint(e, ["mode": "context"], completer: FailingCompleter()))
        let segs = out["segments"] as? [[String: Any]] ?? []
        #expect(segs.count == 1)
        #expect(segs.first?["text"] as? String == "好久没有开照片了")
        #expect((out["flags"] as? [[String: Any]])?.isEmpty ?? true)
    }

    @Test func flagsDegradeToContextWhenLLMUnreachable() async throws {
        let e = editorWithCaptions([("好久没有开照片了", 100, 50)])
        let exec = ToolExecutor(editor: e)
        let out = body(try await exec.captionLint(e, ["mode": "flags"], completer: nil))
        #expect((out["segments"] as? [[String: Any]])?.count == 1)
        #expect(out["note"] != nil)
    }

    @Test func lintFailureDegradesToContext() async throws {
        let e = editorWithCaptions([("好久没有开照片了", 100, 50)])
        let exec = ToolExecutor(editor: e)
        let out = body(try await exec.captionLint(e, ["mode": "flags"], completer: FailingCompleter()))
        #expect((out["segments"] as? [[String: Any]])?.count == 1)
        #expect(out["note"] != nil)
    }

    @Test func pagingCursorEmitsEveryWindowExactlyOnce() async throws {
        // More windows than one page; overlapping spans must not reprocess across pages.
        let count = ToolExecutor.captionLintMaxWindows + 50
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack()])
        // Overlapping captions: each spans 30 frames but starts 10 apart.
        _ = e.placeTextClips((0..<count).map { spec("cap\($0)", start: $0 * 10, duration: 30, group: "g1") })
        let exec = ToolExecutor(editor: e)

        let page1 = body(try await exec.captionLint(e, ["mode": "context"], completer: FailingCompleter()))
        let seg1 = page1["segments"] as? [[String: Any]] ?? []
        #expect(seg1.count == ToolExecutor.captionLintMaxWindows)
        let cursor = try #require(page1["nextClipId"] as? String)

        let page2 = body(try await exec.captionLint(e, ["mode": "context", "afterClipId": cursor], completer: FailingCompleter()))
        let seg2 = page2["segments"] as? [[String: Any]] ?? []
        #expect(seg2.count == 50)
        #expect(page2["nextClipId"] == nil)

        let ids1 = Set(seg1.compactMap { $0["clipId"] as? String })
        let ids2 = Set(seg2.compactMap { $0["clipId"] as? String })
        #expect(ids1.isDisjoint(with: ids2))          // no window emitted twice
        #expect(ids1.union(ids2).count == count)       // every window emitted once
    }

    @Test func noCaptionsReturnsHelpfulNote() async throws {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack()])
        let exec = ToolExecutor(editor: e)
        let out = body(try await exec.captionLint(e, ["mode": "flags"], completer: FailingCompleter()))
        #expect((out["flags"] as? [[String: Any]])?.isEmpty ?? true)
        #expect(out["note"] != nil)
    }

    // MARK: - Reject-path persistence (dismiss)

    @Test func dismissPersistsToLibraryFileAndAppends() throws {
        // Writes to a temp library scope — CaptionStyleStore.libraryURL, isolated per test.
        try withFreshLibrary {
            let e = editorWithCaptions([("我在看视频呢", 0, 40)])
            let exec = ToolExecutor(editor: e)

            let out1 = body(try exec.dismissLintTerm(e, ["original": "视频"]))
            #expect(out1["dismissed"] as? String == "视频")
            #expect(out1["lintDismissals"] as? [String] == ["视频"])
            #expect(out1["warning"] == nil)  // 2 CJK chars is distinctive, not broad

            // A different term appends; re-dismissing an existing one is idempotent.
            _ = try exec.dismissLintTerm(e, ["original": "开照片"])
            let out3 = body(try exec.dismissLintTerm(e, ["original": "视频"]))
            #expect((out3["lintDismissals"] as? [String])?.sorted() == ["开照片", "视频"].sorted())

            // Persisted to the profile file itself.
            let onDisk = CaptionStyleStore.readLayer(at: CaptionStyleStore.libraryURL)["lintDismissals"] as? [String]
            #expect(onDisk?.sorted() == ["开照片", "视频"].sorted())
        }
    }

    @Test func dismissRequiresOriginal() throws {
        let e = editorWithCaptions([("我在看视频呢", 0, 40)])
        let exec = ToolExecutor(editor: e)
        #expect(throws: (any Error).self) {
            try exec.dismissLintTerm(e, ["reason": "no original"])
        }
    }

    @Test func dismissedTermSuppressesSameFlagOnNextRun() async throws {
        // End-to-end: dismiss writes the library scope, then the same stubbed flag is suppressed on the
        // next run because library dismissals feed lintExclusions. Library is an isolated temp dir.
        try await withFreshLibrary {
            let e = editorWithCaptions([("我在看视频呢", 0, 40)])  // projectURL nil → resolve reads library
            let target = clipId(e, text: "我在看视频呢")
            let exec = ToolExecutor(editor: e)
            _ = try exec.dismissLintTerm(e, ["original": "视频"])

            let stub = StubCompleter(response: """
            [{"clipId":"\(target)","original":"视频","suggestion":"视屏","reason":"x","confidence":0.9}]
            """)
            let out = body(try await exec.captionLint(e, ["mode": "flags"], completer: stub))
            #expect((out["flags"] as? [[String: Any]])?.isEmpty ?? true)
            #expect((out["dismissedCount"] as? Int ?? 0) >= 1)
        }
    }

    @Test func captionStyleReadListsDismissals() throws {
        try withFreshLibrary {
            let e = editorWithCaptions([("我在看视频呢", 0, 40)])
            let exec = ToolExecutor(editor: e)
            _ = try exec.dismissLintTerm(e, ["original": "视频"])
            _ = try exec.dismissLintTerm(e, ["original": "开照片"])
            let out = body(try exec.captionStyle(e, [:]))
            #expect((out["lintDismissals"] as? [String])?.sorted() == ["开照片", "视频"].sorted())
        }
    }

    @Test func shortDismissalWarnsButLongOneDoesNot() {
        #expect(ToolExecutor.shortDismissalWarning("啊") != nil)    // single CJK char — broad
        #expect(ToolExecutor.shortDismissalWarning("ok") != nil)     // 2 Latin letters — broad
        #expect(ToolExecutor.shortDismissalWarning("视频") == nil)   // 2 CJK chars — distinctive
        #expect(ToolExecutor.shortDismissalWarning("okay") == nil)   // 4 Latin letters — distinctive
    }

    /// Deliverable 3 — the near-sound lint safety net composes end-to-end with a per-project model
    /// override. Captions containing 开照片 and a stubbed completer suggesting 拍照片: the flag surfaces
    /// (flag-only default), then applying it via update_text rewrites the clip and promotes the widened
    /// term — all while the project is pinned to a non-default local engine, proving the two features
    /// are independent (the report's exact 开照片→拍照片 scenario).
    @Test func nearSoundLintFlagAndApplyComposeUnderModelOverride() async throws {
        try await withFreshLibrary {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lint-override-\(UUID().uuidString).palmier", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let e = editorWithCaptions([("好久没有开照片了", 100, 50)])
            e.projectURL = dir
            e.transcriptionLocalModel = .whisper  // project pinned off the app-global engine
            e.captionWordSourceProvider = { _ in
                FixedWordSource(words: [WordTiming(text: "好久没有拍照片了", startFrame: 100, endFrame: 150)])
            }
            let target = clipId(e, text: "好久没有开照片了")
            let exec = ToolExecutor(editor: e)

            // Flag-only default: the near-sound error surfaces, nothing is applied.
            let stub = StubCompleter(response: """
            [{"clipId":"\(target)","original":"开照片","suggestion":"拍照片","reason":"near-sound","confidence":0.8}]
            """)
            let lint = body(try await exec.captionLint(e, ["mode": "flags"], completer: stub))
            #expect((lint["flags"] as? [[String: Any]])?.count == 1)
            #expect((lint["applied"] as? [[String: Any]])?.isEmpty ?? true)
            #expect(e.timeline.tracks.flatMap(\.clips).first { $0.id == target }?.textContent == "好久没有开照片了")

            // Applying the suggestion via update_text rewrites the clip and promotes the widened term.
            let apply = body(await exec.execute(name: "update_text", args: [
                "entries": [["clipId": target, "content": "好久没有拍照片了"]],
            ]))
            #expect((apply["promoted"] as? [[String: Any]])?.isEmpty == false)
            #expect(e.timeline.tracks.flatMap(\.clips).first { $0.id == target }?.textContent == "好久没有拍照片了")

            // The override is untouched by the lint/edit flow — model selection and lint are independent.
            #expect(e.resolvedLocalEngine == .whisper)
        }
    }
}
