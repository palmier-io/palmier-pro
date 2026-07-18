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

// MARK: - Core linter (pure, no editor)

@Suite struct CaptionLinterTests {
    private func window(_ id: String, _ text: String, start: Int = 100, end: Int = 150, prev: String? = nil, next: String? = nil) -> LintWindow {
        LintWindow(clipId: id, startFrame: start, endFrame: end, text: text, prevText: prev, nextText: next)
    }

    @Test func flagsNearSoundSubstitutionWithContextAndFrames() async throws {
        let w = window("c1", "好久没有开视频了", start: 100, end: 150, next: "今天来拍个 vlog")
        let stub = StubCompleter(response: """
        [{"clipId":"c1","original":"开视频","suggestion":"拍视频","reason":"near-sound; context is shooting a vlog","confidence":0.8}]
        """)
        let flags = try await CaptionLinter.flag(windows: [w], exclusions: LintExclusions(terms: []), completer: stub)
        #expect(flags.count == 1)
        let f = try #require(flags.first)
        #expect(f.clipId == "c1")
        #expect(f.original == "开视频")
        #expect(f.suggestion == "拍视频")
        #expect(f.startFrame == 100 && f.endFrame == 150)
        #expect(f.confidence == 0.8)
        #expect(f.reason.contains("near-sound"))
    }

    @Test func fillersAndGlossaryTermsAreNotFlagged() async throws {
        let excl = LintExclusions(terms: ["呃", "小明"])  // filler + a glossary variant
        #expect(excl.excludes(original: "呃"))
        #expect(excl.excludes(original: "小明"))
        #expect(!excl.excludes(original: "拍视频"))

        let w = window("c1", "呃 小明 去 拍视频")
        let stub = StubCompleter(response: """
        [{"clipId":"c1","original":"呃","suggestion":"啊","reason":"x","confidence":0.9},
         {"clipId":"c1","original":"小明","suggestion":"小名","reason":"x","confidence":0.9}]
        """)
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
        let w = window("c1", "好久没有开视频了")
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
@Suite struct CaptionLintToolTests {
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

    @Test func flagsModeSurfacesButDoesNotApply() async throws {
        let e = editorWithCaptions([("好久没有开视频了", 100, 50), ("今天来拍个 vlog", 150, 50)])
        let target = clipId(e, text: "好久没有开视频了")
        let stub = StubCompleter(response: """
        [{"clipId":"\(target)","original":"开视频","suggestion":"拍视频","reason":"near-sound","confidence":0.8}]
        """)
        let exec = ToolExecutor(editor: e)
        let result = try await exec.captionLint(e, ["mode": "flags"], completer: stub)
        let out = body(result)

        let flags = out["flags"] as? [[String: Any]] ?? []
        #expect(flags.count == 1)
        #expect(flags.first?["original"] as? String == "开视频")
        #expect(flags.first?["frameRange"] as? [Int] == [100, 150])
        #expect((out["applied"] as? [[String: Any]])?.isEmpty ?? true)
        // Nothing changed without a threshold.
        #expect(e.timeline.tracks.flatMap(\.clips).first { $0.id == target }?.textContent == "好久没有开视频了")
    }

    @Test func autoApplyAboveThresholdRewritesTheClip() async throws {
        let e = editorWithCaptions([("好久没有开视频了", 100, 50)])
        let target = clipId(e, text: "好久没有开视频了")
        let stub = StubCompleter(response: """
        [{"clipId":"\(target)","original":"开视频","suggestion":"拍视频","reason":"near-sound","confidence":0.8}]
        """)
        let exec = ToolExecutor(editor: e)
        let result = try await exec.captionLint(e, ["mode": "flags", "autoApplyThreshold": 0.7], completer: stub)
        let out = body(result)

        let applied = out["applied"] as? [[String: Any]] ?? []
        #expect(applied.count == 1)
        #expect(applied.first?["suggestion"] as? String == "拍视频")
        #expect((out["flags"] as? [[String: Any]])?.isEmpty ?? true)
        #expect(e.timeline.tracks.flatMap(\.clips).first { $0.id == target }?.textContent == "好久没有拍视频了")
    }

    @Test func belowThresholdStaysFlagged() async throws {
        let e = editorWithCaptions([("好久没有开视频了", 100, 50)])
        let target = clipId(e, text: "好久没有开视频了")
        let stub = StubCompleter(response: """
        [{"clipId":"\(target)","original":"开视频","suggestion":"拍视频","reason":"near-sound","confidence":0.5}]
        """)
        let exec = ToolExecutor(editor: e)
        let out = body(try await exec.captionLint(e, ["mode": "flags", "autoApplyThreshold": 0.9], completer: stub))
        #expect((out["flags"] as? [[String: Any]])?.count == 1)
        #expect((out["applied"] as? [[String: Any]])?.isEmpty ?? true)
        #expect(e.timeline.tracks.flatMap(\.clips).first { $0.id == target }?.textContent == "好久没有开视频了")
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
        let e = editorWithCaptions([("好久没有开视频了", 100, 50)])
        let exec = ToolExecutor(editor: e)
        // A failing completer proves context mode never calls it.
        let out = body(try await exec.captionLint(e, ["mode": "context"], completer: FailingCompleter()))
        let segs = out["segments"] as? [[String: Any]] ?? []
        #expect(segs.count == 1)
        #expect(segs.first?["text"] as? String == "好久没有开视频了")
        #expect((out["flags"] as? [[String: Any]])?.isEmpty ?? true)
    }

    @Test func flagsDegradeToContextWhenLLMUnreachable() async throws {
        let e = editorWithCaptions([("好久没有开视频了", 100, 50)])
        let exec = ToolExecutor(editor: e)
        let out = body(try await exec.captionLint(e, ["mode": "flags"], completer: nil))
        #expect((out["segments"] as? [[String: Any]])?.count == 1)
        #expect(out["note"] != nil)
    }

    @Test func lintFailureDegradesToContext() async throws {
        let e = editorWithCaptions([("好久没有开视频了", 100, 50)])
        let exec = ToolExecutor(editor: e)
        let out = body(try await exec.captionLint(e, ["mode": "flags"], completer: FailingCompleter()))
        #expect((out["segments"] as? [[String: Any]])?.count == 1)
        #expect(out["note"] != nil)
    }

    @Test func noCaptionsReturnsHelpfulNote() async throws {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack()])
        let exec = ToolExecutor(editor: e)
        let out = body(try await exec.captionLint(e, ["mode": "flags"], completer: FailingCompleter()))
        #expect((out["flags"] as? [[String: Any]])?.isEmpty ?? true)
        #expect(out["note"] != nil)
    }
}
