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

    @Test func unknownProvenanceReplacedAndConflictLogged() {
        let caption = captionClip(id: "cap", start: 0, duration: 60, text: "pre feature text", generatedText: nil)
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [word("one", 0, 30), word("two", 30, 60)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<60], trigger: "t", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk
        )
        #expect(plan.replacements.first?.text == "one two")
        #expect(plan.report.conflicts.count == 1)   // logged even though replaced
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
            word("我掉得", 0, 30), word("really", 30, 60), word("low。", 60, 90),
            word("oh", 90, 120), word("god。", 120, 150),
        ])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<150], trigger: "t", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk
        )
        #expect(plan.replacements.first?.text == "我掉得 really low。 oh god。")
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
    private func editorWithCaptions() -> EditorViewModel {
        let e = EditorViewModel()
        e.timeline = timeline([Fixtures.videoTrack(clips: [captionClip(id: "c", start: 0, duration: 30, text: "x", generatedText: "x")])])
        return e
    }

    @Test func trimProducesUnionSpan() {
        let e = editorWithCaptions()
        let before = timeline([Fixtures.audioTrack(clips: [Fixtures.clip(id: "a", mediaType: .audio, start: 0, duration: 90)])])
        let after = timeline([Fixtures.audioTrack(clips: [Fixtures.clip(id: "a", mediaType: .audio, start: 0, duration: 60)])])
        let spans = CaptionResyncEngine.mergeSpans(e.captionResyncAffectedSpans(before: before, after: after))
        #expect(spans == [0..<90])
    }

    @Test func uniformRippleShiftExcludesDownstream() {
        let e = editorWithCaptions()
        func audio(_ id: String, _ s: Int) -> Clip { Fixtures.clip(id: id, mediaType: .audio, start: s, duration: 30) }
        let before = timeline([Fixtures.audioTrack(clips: [audio("A", 0), audio("B", 30), audio("C", 60), audio("D", 90)])])
        let after = timeline([Fixtures.audioTrack(clips: [audio("B", 0), audio("C", 30), audio("D", 60)])])
        let spans = CaptionResyncEngine.mergeSpans(e.captionResyncAffectedSpans(before: before, after: after))
        // A removed at [0,30); B/C/D shifted uniformly by -30 → excluded. Only the seam is affected.
        #expect(spans == [0..<30])
    }

    @Test func insertAffectsOnlyInsertRegion() {
        let e = editorWithCaptions()
        func audio(_ id: String, _ s: Int) -> Clip { Fixtures.clip(id: id, mediaType: .audio, start: s, duration: 30) }
        let before = timeline([Fixtures.audioTrack(clips: [audio("B", 0), audio("C", 30)])])
        let after = timeline([Fixtures.audioTrack(clips: [audio("NEW", 0), audio("B", 30), audio("C", 60)])])
        let spans = CaptionResyncEngine.mergeSpans(e.captionResyncAffectedSpans(before: before, after: after))
        #expect(spans == [0..<30])
    }

    @Test func captionOnlyChangesProduceNoSpan() {
        let e = editorWithCaptions()
        // Two timelines differing only on the text track — audible occupancy identical.
        let before = timeline([Fixtures.audioTrack(clips: [Fixtures.clip(id: "a", mediaType: .audio, start: 0, duration: 90)])])
        let after = before
        #expect(e.captionResyncAffectedSpans(before: before, after: after).isEmpty)
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
}
