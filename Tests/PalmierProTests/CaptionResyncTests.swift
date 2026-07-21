import Foundation
import Testing
@testable import PalmierPro

// Caption resync (L2→L3): engine logic against synthetic timelines with an injected read-only word
// source, plus trigger wiring (trim fires, split does not), undo grouping, and L1/L2 isolation.

// MARK: - Fixtures

/// Read-only word source. Conforming to CaptionWordSource is the only capability it has — there is no
/// write API, so an engine holding one cannot touch asset transcripts (L1) or the cache (L2).
private final class FakeWordSource: CaptionWordSource {
    var words: [WordTiming]
    var uncached: [String]
    private(set) var queriedRanges: [Range<Int>] = []

    init(words: [WordTiming], uncached: [String] = []) {
        self.words = words
        self.uncached = uncached
    }

    func audibleWords(in range: Range<Int>) -> [WordTiming] {
        queriedRanges.append(range)
        return words
            .filter { $0.startFrame < range.upperBound && $0.endFrame > range.lowerBound }
            .sorted { ($0.startFrame, $0.endFrame) < ($1.startFrame, $1.endFrame) }
    }

    func uncachedRefs(in range: Range<Int>) -> [String] { uncached }
}

private func word(_ text: String, _ start: Int, _ end: Int) -> WordTiming {
    WordTiming(text: text, startFrame: start, endFrame: end)
}

@MainActor
private func captionClip(
    id: String, group: String = "g1", start: Int, duration: Int,
    text: String, generatedText: String?, exempt: Bool? = nil, conflict: Bool? = nil
) -> Clip {
    var c = Clip(mediaRef: "", mediaType: .text, sourceClipType: .text, startFrame: start, durationFrames: duration)
    c.id = id
    c.captionGroupId = group
    c.textContent = text
    c.generatedText = generatedText
    c.resyncExempt = exempt
    c.resyncConflict = conflict
    return c
}

/// One caption clip per call — the boundary-preserving default for REPLACE-oriented tests.
private func singleChunk(_ words: [WordTiming], _ maxWords: Int?) -> [[WordTiming]] {
    words.isEmpty ? [] : [words]
}

/// Splits into fixed groups of `maxWords` (or all) — enough for CREATE assertions.
private func cappedChunk(_ words: [WordTiming], _ maxWords: Int?) -> [[WordTiming]] {
    guard let cap = maxWords, cap > 0 else { return words.isEmpty ? [] : [words] }
    return stride(from: 0, to: words.count, by: cap).map { Array(words[$0..<min($0 + cap, words.count)]) }
}

@MainActor
private func timeline(_ tracks: [Track]) -> Timeline {
    var t = Timeline()
    t.fps = 30
    t.tracks = tracks
    return t
}

// MARK: - Engine: REPLACE / REMOVE / match

@MainActor
@Suite struct CaptionResyncEngineTests {
    @Test func trimShrinksCleanCaptionToSurvivingWords() {
        let caption = captionClip(id: "cap", start: 0, duration: 90, text: "one two three", generatedText: "one two three")
        let other = captionClip(id: "far", start: 120, duration: 60, text: "four five", generatedText: "four five")
        let tl = timeline([Fixtures.videoTrack(clips: [caption, other])])
        let src = FakeWordSource(words: [word("one", 0, 30), word("two", 30, 60)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<90], trigger: "Trim Clip", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk
        )

        #expect(plan.replacements.count == 1)
        #expect(plan.replacements.first?.clipId == "cap")
        #expect(plan.replacements.first?.text == "one two")
        #expect(plan.report.updated == [.init(clipId: "cap", before: "one two three", after: "one two")])
        // Far caption never queried — lookups confined to the caption touching the affected span.
        #expect(src.queriedRanges.allSatisfy { $0.lowerBound >= 0 && $0.upperBound <= 90 })
        #expect(plan.report.removed.isEmpty)
    }

    @Test func rebuiltTimingsAreClipRelative() {
        let caption = captionClip(id: "cap", start: 100, duration: 90, text: "old", generatedText: "old")
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [word("hi", 100, 130), word("there", 130, 160)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [100..<190], trigger: "t", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk
        )
        #expect(plan.replacements.first?.wordTimings == [word("hi", 0, 30), word("there", 30, 60)])
    }

    @Test func emptySpanRemovesCaption() {
        let caption = captionClip(id: "cap", start: 0, duration: 90, text: "gone soon", generatedText: "gone soon")
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<90], trigger: "t", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk
        )
        #expect(plan.removals == ["cap"])
        #expect(plan.report.removed == [.init(clipId: "cap", text: "gone soon")])
    }

    @Test func matchingTextIsNoOp() {
        let caption = captionClip(id: "cap", start: 0, duration: 60, text: "one two", generatedText: "one two")
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [word("one", 0, 30), word("two", 30, 60)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<60], trigger: "t", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk
        )
        #expect(!plan.hasWork)
        #expect(plan.report.isEmpty)
    }

    // MARK: - Conflict policy

    @Test func dirtyCaptionPreservedByDefault() {
        let caption = captionClip(id: "cap", start: 0, duration: 60, text: "my hand edit", generatedText: "one two")
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [word("one", 0, 30), word("two", 30, 60)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<60], trigger: "t", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk
        )
        #expect(plan.replacements.isEmpty)
        #expect(plan.report.conflicts == [.init(clipId: "cap", manualText: "my hand edit", newTranscript: "one two")])
    }

    @Test func dirtyCaptionOverwrittenWhenPolicyOverwrite() {
        let caption = captionClip(id: "cap", start: 0, duration: 60, text: "my hand edit", generatedText: "one two")
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [word("one", 0, 30), word("two", 30, 60)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<60], trigger: "t", fps: 30,
            policy: .overwrite, wordSource: src, chunk: singleChunk
        )
        #expect(plan.replacements.first?.text == "one two")
        #expect(plan.report.updated.first?.after == "one two")
    }

    @Test func dirtyCaptionFlaggedWhenPolicyFlag() {
        let caption = captionClip(id: "cap", start: 0, duration: 60, text: "my hand edit", generatedText: "one two")
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [word("one", 0, 30), word("two", 30, 60)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<60], trigger: "t", fps: 30,
            policy: .flag, wordSource: src, chunk: singleChunk
        )
        #expect(plan.replacements.isEmpty)
        #expect(plan.flagged == ["cap"])
        #expect(plan.report.conflicts.count == 1)
    }

    @Test func flagClearsWhenManualTextMatchesAgain() {
        let caption = captionClip(id: "cap", start: 0, duration: 60, text: "one two", generatedText: "stale", conflict: true)
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [word("one", 0, 30), word("two", 30, 60)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<60], trigger: "t", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk
        )
        #expect(plan.clearedFlags == ["cap"])
    }

    @Test func unknownProvenanceFollowsPolicyNeverBlindReplace() {
        // generatedText == nil is hand-authored or pre-feature text: clean requires PROOF, so the
        // conflict policy governs — .preserve keeps the text, .overwrite replaces it.
        let caption = captionClip(id: "cap", start: 0, duration: 60, text: "pre feature text", generatedText: nil)
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [word("one", 0, 30), word("two", 30, 60)])

        let preserved = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<60], trigger: "t", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk
        )
        #expect(preserved.replacements.isEmpty)
        #expect(preserved.report.conflicts.count == 1)

        let overwritten = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<60], trigger: "t", fps: 30,
            policy: .overwrite, wordSource: src, chunk: singleChunk
        )
        #expect(overwritten.replacements.first?.text == "one two")
    }

    @Test func exemptGroupIsUntouched() {
        let caption = captionClip(id: "cap", start: 0, duration: 60, text: "keep me", generatedText: "keep me", exempt: true)
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [word("changed", 0, 30), word("words", 30, 60)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<60], trigger: "t", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk
        )
        #expect(!plan.hasWork)
    }

    @Test func mixedLanguageTextPreservedVerbatim() {
        let caption = captionClip(id: "cap", start: 0, duration: 150, text: "old", generatedText: "old")
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [
            word("我唱得", 0, 30), word("really", 30, 60), word("low。", 60, 90),
            word("oh", 90, 120), word("god。", 120, 150),
        ])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<150], trigger: "t", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk
        )
        #expect(plan.replacements.first?.text == "我唱得 really low。 oh god。")
    }

    // MARK: - CREATE

    @Test func uncoveredSpeechCreatesCaptions() {
        // Group clip covers [0,60); words extend into [60,120) with no covering caption there.
        let caption = captionClip(id: "cap", start: 0, duration: 60, text: "one two", generatedText: "one two")
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [
            word("one", 0, 30), word("two", 30, 60), word("three", 60, 90), word("four", 90, 120),
        ])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<120], trigger: "insert", fps: 30,
            policy: .preserve, wordSource: src, chunk: cappedChunk
        )
        #expect(!plan.creations.isEmpty)
        let createdText = plan.report.created.map(\.text).joined(separator: " ")
        #expect(createdText.contains("three"))
        #expect(createdText.contains("four"))
        // Existing clip matched its own words — no spurious replacement.
        #expect(plan.replacements.isEmpty)
    }

    // MARK: - Cost / span confinement

    @Test func downstreamCaptionsAreNeverQueriedOutsideSpan() {
        let near = captionClip(id: "near", start: 0, duration: 60, text: "gone", generatedText: "gone")
        let far = captionClip(id: "far", start: 900, duration: 60, text: "later words", generatedText: "later words")
        let tl = timeline([Fixtures.videoTrack(clips: [near, far])])
        let src = FakeWordSource(words: [word("later", 900, 930), word("words", 930, 960)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<60], trigger: "ripple", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk
        )
        #expect(plan.removals == ["near"])                       // empty near-span caption removed
        #expect(src.queriedRanges.allSatisfy { $0.upperBound <= 60 })  // far caption never looked up
        #expect(!plan.report.updated.contains { $0.clipId == "far" })
    }
}

// MARK: - Span diff heuristic

@MainActor
@Suite struct CaptionResyncSpanTests {
    private func aud(_ id: String, _ start: Int, _ dur: Int = 30) -> Clip {
        Fixtures.clip(id: id, mediaType: .audio, start: start, duration: dur)
    }
    private func cap(_ id: String, _ start: Int, _ dur: Int = 30) -> Clip {
        captionClip(id: id, start: start, duration: dur, text: "x", generatedText: "x")
    }
    private func tl(caps: [Clip], audio: [Clip]) -> Timeline {
        timeline([Fixtures.videoTrack(clips: caps), Fixtures.audioTrack(clips: audio)])
    }
    private func spans(_ before: Timeline, _ after: Timeline) -> [Range<Int>] {
        CaptionResyncEngine.mergeSpans(EditorViewModel().captionResyncAffectedSpans(before: before, after: after))
    }

    @Test func trimProducesUnionSpan() {
        let before = tl(caps: [cap("c", 0, 90)], audio: [aud("a", 0, 90)])
        let after = tl(caps: [cap("c", 0, 90)], audio: [aud("a", 0, 60)])
        #expect(spans(before, after) == [0..<90])
    }

    @Test func uniformRippleShiftExcludesDownstream() {
        // Ripple-delete A and its caption; everything downstream (audio AND captions) shifts -30 together.
        let before = tl(caps: [cap("cA", 0), cap("cB", 30), cap("cC", 60), cap("cD", 90)],
                        audio: [aud("A", 0), aud("B", 30), aud("C", 60), aud("D", 90)])
        let after = tl(caps: [cap("cB", 0), cap("cC", 30), cap("cD", 60)],
                       audio: [aud("B", 0), aud("C", 30), aud("D", 60)])
        // Captions stayed aligned with their audio → only the deleted seam is affected.
        #expect(spans(before, after) == [0..<30])
    }

    @Test func insertAffectsOnlyInsertRegion() {
        let before = tl(caps: [cap("cB", 0), cap("cC", 30)], audio: [aud("B", 0), aud("C", 30)])
        let after = tl(caps: [cap("cB", 30), cap("cC", 60)], audio: [aud("NEW", 0), aud("B", 30), aud("C", 60)])
        #expect(spans(before, after) == [0..<30])
    }

    @Test func captionOnlyChangesProduceNoSpan() {
        let before = tl(caps: [cap("c", 0, 90)], audio: [aud("a", 0, 90)])
        #expect(EditorViewModel().captionResyncAffectedSpans(before: before, after: before).isEmpty)
    }

    // F1: a two-direction block swap must resync BOTH sides, and do so identically every run.
    @Test func blockSwapResyncsBothSidesDeterministically() {
        // Captions stay put; the two audio blocks swap places → each now sits under the other's caption.
        let before = tl(caps: [cap("c1", 0), cap("c2", 30)], audio: [aud("A", 0), aud("B", 30)])
        let after = tl(caps: [cap("c1", 0), cap("c2", 30)], audio: [aud("B", 0), aud("A", 30)])
        let expected: [Range<Int>] = [0..<60]
        for _ in 0..<50 {
            #expect(spans(before, after) == expected)   // stable across runs — no hash-order dependence
        }
    }

    // F2: ≥2 same-delta clips moving onto a captioned, occupied region must resync the destination.
    @Test func moveOntoOccupiedRegionResyncsDestination() {
        let before = tl(caps: [cap("cZ", 200)], audio: [aud("X", 0), aud("Y", 30), aud("Z", 200)])
        // X and Y both shift +200; Z is overwritten at the destination; the caption there stays put.
        let after = tl(caps: [cap("cZ", 200)], audio: [aud("X", 200), aud("Y", 230)])
        let result = spans(before, after)
        // Destination region [200,230) (under cZ) is resynced despite X/Y sharing a delta.
        #expect(result.contains { $0.lowerBound <= 200 && $0.upperBound >= 230 })
    }
}

// MARK: - Trigger wiring + undo + isolation

@MainActor
@Suite struct CaptionResyncTriggerTests {
    private func editorWithAudioAndCaption(captionText: String, generatedText: String) -> (EditorViewModel, FakeWordSource) {
        let e = EditorViewModel()
        let audio = Fixtures.clip(id: "audio", mediaRef: "m", mediaType: .audio, start: 0, duration: 90)
        let caption = captionClip(id: "cap", start: 0, duration: 90, text: captionText, generatedText: generatedText)
        e.timeline = timeline([
            Fixtures.videoTrack(clips: [caption]),
            Fixtures.audioTrack(clips: [audio]),
        ])
        let src = FakeWordSource(words: [word("one", 0, 30), word("two", 30, 60)])
        e.captionWordSourceProvider = { _ in src }
        return (e, src)
    }

    @Test func trimTriggersResyncAndUpdatesCaption() {
        let (e, _) = editorWithAudioAndCaption(captionText: "one two three", generatedText: "one two three")
        e.trimClips([(clipId: "audio", trimStartFrame: 0, trimEndFrame: 30)])

        let cap = e.timeline.tracks[0].clips.first { $0.id == "cap" }
        #expect(cap?.textContent == "one two")
    }

    @Test func splitTriggersNoResyncAndNoLookups() {
        let (e, src) = editorWithAudioAndCaption(captionText: "one two three", generatedText: "one two three")
        _ = e.splitClip(clipId: "audio", atFrame: 45)

        #expect(src.queriedRanges.isEmpty)                                  // never invoked
        #expect(e.timeline.tracks[0].clips.first { $0.id == "cap" }?.textContent == "one two three")
    }

    @Test func undoRevertsTriggerAndResyncTogether() {
        let (e, _) = editorWithAudioAndCaption(captionText: "one two three", generatedText: "one two three")
        let manager = UndoManager()
        e.undo.attach(manager)
        let before = e.timeline

        e.trimClips([(clipId: "audio", trimStartFrame: 0, trimEndFrame: 30)])
        #expect(e.timeline.tracks[0].clips.first { $0.id == "cap" }?.textContent == "one two")

        manager.undo()
        #expect(e.timeline == before)   // one undo restores audio trim AND caption text
    }

    @Test func resyncNeverMutatesNonCaptionClips() {
        let (e, _) = editorWithAudioAndCaption(captionText: "one two three", generatedText: "one two three")
        let audioBefore = e.timeline.tracks[1].clips
        e.trimClips([(clipId: "audio", trimStartFrame: 0, trimEndFrame: 0)])  // no-op trim: audio unchanged
        // The audio (L1 source) is byte-identical; resync only ever writes caption (L3) clips.
        #expect(e.timeline.tracks[1].clips == audioBefore)
    }

    @Test func dirtyCaptionSurvivesUnrelatedTrimUnderPreserve() {
        let (e, _) = editorWithAudioAndCaption(captionText: "hand edited", generatedText: "one two three")
        e.trimClips([(clipId: "audio", trimStartFrame: 0, trimEndFrame: 30)])
        // preserve is the default → manual text kept, clip not overwritten.
        #expect(e.timeline.tracks[0].clips.first { $0.id == "cap" }?.textContent == "hand edited")
    }

    // set_clip_properties applies timing outside withTimelineSwap — it reconciles via the same hook.
    @Test func agentTimingPropertyTriggersResync() {
        let (e, _) = editorWithAudioAndCaption(captionText: "one two three", generatedText: "one two three")
        let before = e.timeline
        e.undo.perform("Set Clip Property (Agent)") {
            e.commitClipProperty(clipId: "audio") { $0.trimEndFrame = 30; $0.setDuration(60) }
            e.resyncCaptionsAfterSwap(before: before, trigger: "Set Clip Property (Agent)")
        }
        #expect(e.timeline.tracks[0].clips.first { $0.id == "cap" }?.textContent == "one two")
    }

    @Test func agentNonTimingPropertyDoesNotTriggerResync() {
        let (e, src) = editorWithAudioAndCaption(captionText: "one two three", generatedText: "one two three")
        let before = e.timeline
        e.undo.perform("Set Clip Property (Agent)") {
            e.commitClipProperty(clipId: "audio") { $0.opacity = 0.5 }
            e.resyncCaptionsAfterSwap(before: before, trigger: "Set Clip Property (Agent)")
        }
        #expect(src.queriedRanges.isEmpty)
        #expect(e.timeline.tracks[0].clips.first { $0.id == "cap" }?.textContent == "one two three")
    }

    // Drives the REAL set_clip_properties tool (not resyncCaptionsAfterSwap directly) to prove the wiring.
    @Test func setClipPropertiesToolPathTriggersResync() async {
        let audio = Fixtures.clip(id: "audio", mediaRef: "m", mediaType: .audio, start: 0, duration: 90)
        let caption = captionClip(id: "cap", start: 0, duration: 90, text: "one two three", generatedText: "one two three")
        let h = ToolHarness(timeline: timeline([Fixtures.videoTrack(clips: [caption]), Fixtures.audioTrack(clips: [audio])]))
        let src = FakeWordSource(words: [word("one", 0, 30), word("two", 30, 60)])
        h.editor.captionWordSourceProvider = { _ in src }

        _ = await h.runRaw("set_clip_properties", args: ["clipIds": ["audio"], "trimEndFrame": 30])
        #expect(!src.queriedRanges.isEmpty)
        #expect(h.editor.timeline.tracks[0].clips.first { $0.id == "cap" }?.textContent == "one two")
    }
}

// F3: the production provider is cache-only — reads on-disk transcripts, never triggers ASR, never writes.
@MainActor
@Suite struct CaptionResyncIsolationTests {
    @Test func providerReadsCacheOnlyAndWritesNothing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pp-resync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("clip.mov")
        try Data("audio".utf8).write(to: file)

        let e = EditorViewModel()
        let asset = MediaAsset(id: "m", url: file, type: .audio, name: "m", duration: 3)
        asset.hasAudio = true
        e.mediaAssets.append(asset)
        e.mediaManifest.entries.append(MediaManifestEntry(id: "m", name: "m", type: .audio, source: .external(absolutePath: file.path), duration: 3))
        e.timeline = timeline([Fixtures.audioTrack(clips: [Fixtures.clip(id: "a", mediaRef: "m", mediaType: .audio, start: 0, duration: 90)])])

        let cacheDir = TranscriptCache.directory
        func listing() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? []).sorted() }
        let before = listing()

        let provider = TimelineTranscriptProvider(editor: e)
        // No transcript cached → cache-only read yields nothing and reports the ref uncached; no ASR, no write.
        #expect(provider.audibleWords(in: 0..<90).isEmpty)
        #expect(provider.uncachedRefs(in: 0..<90) == ["m"])
        #expect(listing() == before)   // TranscriptCache directory untouched — resync never writes L1/L2.
    }
}

// A clean caption over a source whose transcript is not cached must be PRESERVED, not deleted —
// the empty word span is a missing read, not a speech cut. A genuinely-cached empty span still removes.
@MainActor
@Suite struct CaptionResyncColdCacheTests {
    @Test func uncachedRefPreservesCaptionInsteadOfDeleting() {
        let caption = captionClip(id: "cap", start: 0, duration: 90, text: "开照片", generatedText: "开照片")
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [], uncached: ["m"])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<90], trigger: "Trim Clip", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk)

        #expect(plan.removals.isEmpty)
        #expect(plan.report.conflicts.contains { $0.clipId == "cap" && $0.newTranscript.contains("not cached") })
    }

    @Test func cachedEmptySpanStillRemovesCaption() {
        let caption = captionClip(id: "cap", start: 0, duration: 90, text: "开照片", generatedText: "开照片")
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [], uncached: [])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<90], trigger: "Trim Clip", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk)

        #expect(plan.removals == ["cap"])
    }
}

// Round-2 review regressions: an unrelated uncached ref must not freeze resync when cached words
// exist, and new chunks must never span a surviving caption island.
@MainActor
@Suite struct CaptionResyncRoundTwoTests {
    @Test func cachedWordsResyncDespiteUnrelatedUncachedRef() {
        let caption = captionClip(id: "cap", start: 0, duration: 60, text: "旧的", generatedText: "旧的")
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [word("新", 0, 30), word("的", 30, 60)], uncached: ["music-bed"])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<60], trigger: "Trim Clip", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk)

        #expect(plan.replacements.first { $0.clipId == "cap" }?.text == "新 的")
    }

    @Test func unchangedTextStillRefreshesStaleTimings() {
        var caption = captionClip(id: "cap", start: 0, duration: 60, text: "你 好", generatedText: "你 好")
        caption.wordTimings = [WordTiming(text: "你", startFrame: 0, endFrame: 10),
                               WordTiming(text: "好", startFrame: 10, endFrame: 20)]
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [word("你", 0, 30), word("好", 30, 60)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<60], trigger: "Change Speed", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk)

        let repl = plan.replacements.first { $0.clipId == "cap" }
        #expect(repl?.text == "你 好")
        #expect(repl?.wordTimings.last?.endFrame == 60)
    }
}

// Round-3: an uncached ref with only PARTIAL cached word coverage must preserve the caption —
// resyncing on half the words would shrink it to the cached half.
@MainActor
@Suite struct CaptionResyncPartialCacheTests {
    @Test func partialCoverageWithUncachedRefPreservesCaption() {
        let caption = captionClip(id: "cap", start: 0, duration: 120, text: "前 半 后 半", generatedText: "前 半 后 半")
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        // Words cover only the first half of the caption's span; a second ref is uncached.
        let src = FakeWordSource(words: [word("前", 0, 30), word("半", 30, 55)], uncached: ["m2"])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<120], trigger: "Trim Clip", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk)

        #expect(plan.removals.isEmpty)
        #expect(plan.replacements.isEmpty)
        #expect(plan.report.conflicts.contains { $0.clipId == "cap" && $0.newTranscript.contains("not cached") })
    }
}
