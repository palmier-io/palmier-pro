import Foundation
import Testing
@testable import PalmierPro

// Caption resync (L2→L3): engine logic against synthetic timelines with an injected read-only word
// source, plus trigger wiring (trim fires, split does not), undo grouping, and L1/L2 isolation.

// MARK: - Fixtures

/// Read-only word source. Conforming to CaptionWordSource is the only capability it has — there is no
/// write API, so an engine holding one cannot touch asset transcripts (L1) or the cache (L2).
final class FakeWordSource: CaptionWordSource {
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

    @Test func emptySpanPreservesCustomCaptionByDefault() {
        // A custom title (nil generatedText) placed over a now-silent span is NOT deleted under preserve.
        let caption = captionClip(id: "cap", start: 0, duration: 90, text: "MY TITLE", generatedText: nil)
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<90], trigger: "t", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk
        )
        #expect(!plan.removals.contains("cap"))
        #expect(plan.report.conflicts.first?.clipId == "cap")
        #expect(plan.report.conflicts.first?.reason.contains("unknown provenance") == true)
    }

    @Test func emptySpanRemovesCustomCaptionWhenOverwrite() {
        let caption = captionClip(id: "cap", start: 0, duration: 90, text: "MY TITLE", generatedText: nil)
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<90], trigger: "t", fps: 30,
            policy: .overwrite, wordSource: src, chunk: singleChunk
        )
        #expect(plan.removals == ["cap"])
    }

    @Test func emptySpanFlagsCustomCaptionWhenFlag() {
        let caption = captionClip(id: "cap", start: 0, duration: 90, text: "MY TITLE", generatedText: nil)
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<90], trigger: "t", fps: 30,
            policy: .flag, wordSource: src, chunk: singleChunk
        )
        #expect(!plan.removals.contains("cap"))
        #expect(plan.flagged == ["cap"])
        #expect(plan.report.conflicts.first?.clipId == "cap")
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
        #expect(plan.report.conflicts.map { [$0.clipId, $0.manualText, $0.newTranscript] } == [["cap", "my hand edit", "one two"]])
        #expect(plan.report.conflicts.first?.reason.contains("manual edit preserved") == true)
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

    @Test func unknownProvenancePreservedByDefault() {
        // nil generatedText = unknown provenance (a re-broken or add_texts-joined custom caption). Under
        // the default preserve policy it is treated as dirty: kept, conflict-logged, never overwritten.
        let caption = captionClip(id: "cap", start: 0, duration: 60, text: "my custom line break", generatedText: nil)
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [word("one", 0, 30), word("two", 30, 60)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<60], trigger: "t", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk
        )
        #expect(plan.replacements.isEmpty)
        #expect(plan.report.conflicts.map { [$0.clipId, $0.manualText, $0.newTranscript] } == [["cap", "my custom line break", "one two"]])
        #expect(plan.report.conflicts.first?.reason.contains("unknown provenance") == true)
    }

    @Test func unknownProvenanceOverwrittenWhenPolicyOverwrite() {
        let caption = captionClip(id: "cap", start: 0, duration: 60, text: "my custom line break", generatedText: nil)
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [word("one", 0, 30), word("two", 30, 60)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<60], trigger: "t", fps: 30,
            policy: .overwrite, wordSource: src, chunk: singleChunk
        )
        #expect(plan.replacements.first?.text == "one two")
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

// MARK: - Boundary retiming (onset rollback / trailing-silence tighten)

@MainActor
@Suite struct CaptionResyncRetimeTests {
    // The bug case: onset rollback moved 「我」's true start to 484 while the caption still begins at 529.
    // A clean clip must follow its words back — extend [529,571] → [484,571] and rebase its timings.
    @Test func cleanClipExtendsToRolledBackOnset() {
        let caption = captionClip(id: "cap", start: 529, duration: 42, text: "我 hello", generatedText: "我 hello")
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [word("我", 484, 550), word("hello", 550, 571)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [529..<571], trigger: "resync_captions", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk
        )
        #expect(plan.replacements.first?.startFrame == 484)
        #expect(plan.replacements.first?.durationFrames == 571 - 484)
        #expect(plan.replacements.first?.wordTimings == [word("我", 0, 66), word("hello", 66, 87)])
        #expect(plan.report.retimed == [.init(clipId: "cap", beforeStart: 529, beforeEnd: 571, afterStart: 484, afterEnd: 571)])
        #expect(plan.report.updated.isEmpty)  // text unchanged — retime only
    }

    @Test func retimeClampsAgainstTrackNeighbor() {
        // A previous caption (different, exempt group so it isn't itself resolved) ends at 490; the onset
        // wants 484 but the clip must not overlap it → start clamps to 490.
        let prev = captionClip(id: "prev", group: "g0", start: 400, duration: 90, text: "before", generatedText: "before", exempt: true)
        let caption = captionClip(id: "cap", group: "g1", start: 529, duration: 42, text: "我 hello", generatedText: "我 hello")
        let tl = timeline([Fixtures.videoTrack(clips: [prev, caption])])
        let src = FakeWordSource(words: [word("我", 484, 550), word("hello", 550, 571)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [400..<571], trigger: "resync_captions", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk
        )
        let cap = plan.replacements.first { $0.clipId == "cap" }
        #expect(cap?.startFrame == 490)                 // clamped to prev.endFrame, not 484
        #expect(cap?.durationFrames == 571 - 490)
        #expect(!plan.replacements.contains { $0.clipId == "prev" })  // exempt group untouched
    }

    @Test func dirtyClipBoundariesNeverRetimed() {
        // Unknown provenance (nil generatedText) → dirty; even under overwrite the text is rebuilt but the
        // boundaries are policy-governed and must stay put.
        let caption = captionClip(id: "cap", start: 529, duration: 42, text: "old text", generatedText: nil)
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [word("我", 484, 550), word("hello", 550, 571)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [529..<571], trigger: "resync_captions", fps: 30,
            policy: .overwrite, wordSource: src, chunk: singleChunk
        )
        #expect(plan.replacements.first?.text == "我 hello")
        #expect(plan.replacements.first?.startFrame == nil)
        #expect(plan.replacements.first?.durationFrames == nil)
        #expect(plan.report.retimed.isEmpty)
    }

    @Test func trailingSilenceTightensEnd() {
        // Words end at 90 but the clip runs to 120 — the trailing silence tightens the end to 90.
        let caption = captionClip(id: "cap", start: 0, duration: 120, text: "one two", generatedText: "one two")
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [word("one", 0, 45), word("two", 45, 90)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<120], trigger: "resync_captions", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk
        )
        #expect(plan.replacements.first?.startFrame == 0)          // start unmoved
        #expect(plan.replacements.first?.durationFrames == 90)     // end tightened 120 → 90
        #expect(plan.report.retimed.first?.afterEnd == 90)
    }

    @Test func subThresholdDriftIsNoOp() {
        // First word starts at 2 (2-frame drift) — within the churn threshold, so nothing moves.
        let caption = captionClip(id: "cap", start: 0, duration: 60, text: "one two", generatedText: "one two")
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [word("one", 2, 30), word("two", 30, 60)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<60], trigger: "resync_captions", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk
        )
        #expect(!plan.hasWork)
        #expect(plan.report.retimed.isEmpty)
    }

    @Test func retimedAppearsInAgentPayload() {
        let caption = captionClip(id: "cap", start: 529, duration: 42, text: "我 hello", generatedText: "我 hello")
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [word("我", 484, 550), word("hello", 550, 571)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [529..<571], trigger: "resync_captions", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk
        )
        let retimed = plan.report.agentPayload["retimed"] as? [[String: Any]]
        #expect(retimed?.first?["clipId"] as? String == "cap")
        #expect(retimed?.first?["afterStart"] as? Int == 484)
        #expect(retimed?.first?["afterEnd"] as? Int == 571)
    }

    // Whole-group resync_captions tool path applies the retiming end to end (plan → apply → timeline).
    @Test func resyncCaptionsToolAppliesRetiming() async {
        let caption = captionClip(id: "cap", start: 529, duration: 42, text: "我 hello", generatedText: "我 hello")
        let h = ToolHarness(timeline: timeline([Fixtures.videoTrack(clips: [caption])]))
        let src = FakeWordSource(words: [word("我", 484, 550), word("hello", 550, 571)])
        h.editor.captionWordSourceProvider = { _ in src }

        _ = await h.runRaw("resync_captions", args: ["captionGroupId": "g1"])
        let cap = h.editor.timeline.tracks[0].clips.first { $0.id == "cap" }
        #expect(cap?.startFrame == 484)
        #expect(cap?.durationFrames == 571 - 484)
    }

    // Retiming must converge: a second identical resync on the already-retimed timeline does nothing.
    // Guards the `start != clip.startFrame` churn threshold in retimedBounds against regression.
    @Test func retimingIsIdempotent() async {
        let caption = captionClip(id: "cap", start: 529, duration: 42, text: "我 hello", generatedText: "我 hello")
        let h = ToolHarness(timeline: timeline([Fixtures.videoTrack(clips: [caption])]))
        let src = FakeWordSource(words: [word("我", 484, 550), word("hello", 550, 571)])
        h.editor.captionWordSourceProvider = { _ in src }

        _ = await h.runRaw("resync_captions", args: ["captionGroupId": "g1"])
        let retimed = h.editor.timeline.tracks[0].clips.first { $0.id == "cap" }
        #expect(retimed?.startFrame == 484 && retimed?.durationFrames == 571 - 484)

        let plan2 = CaptionResyncEngine.plan(
            timeline: h.editor.timeline, triggerSpans: [484..<571], trigger: "resync_captions", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk
        )
        #expect(!plan2.hasWork)
        #expect(plan2.report.retimed.isEmpty)
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

// A1: resync materialises the project glossary onto the cached raw transcript (exactly as caption
// GENERATION does), so a corrected caption is never silently reverted to the raw mis-heard spelling.
@MainActor
@Suite struct CaptionResyncMaterialisationTests {
    private func openEyeCorrector() -> GlossaryCorrector {
        GlossaryCorrector(terms: [GlossaryTerm(canonical: "OpenAI", variants: ["open eye"], provenance: "test", confidence: .declared)])
    }
    private let rawOpenEye = TranscriptionResult(
        text: "open eye",
        language: "en-US",
        words: [TranscriptionWord(text: "open", start: 0.0, end: 0.5), TranscriptionWord(text: "eye", start: 0.5, end: 1.0)],
        segments: [TranscriptionSegment(text: "open eye", start: 0.0, end: 1.0)]
    )
    private func provider(_ corrector: GlossaryCorrector, source: Clip) -> TimelineTranscriptProvider {
        let frag = TimelineTranscriptProvider.Fragment(clip: source, url: URL(fileURLWithPath: "/tmp/m.mov"), mediaRef: "m")
        return TimelineTranscriptProvider(fragments: [frag], fps: 30, corrector: corrector, read: { _ in self.rawOpenEye })
    }
    private func source() -> Clip { Fixtures.clip(id: "a", mediaRef: "m", mediaType: .audio, start: 0, duration: 90) }

    @Test func providerMaterialisesCorrectionOntoCachedWords() {
        let words = provider(openEyeCorrector(), source: source()).audibleWords(in: 0..<90)
        #expect(words.contains { $0.text == "OpenAI" }, "corrected canonical surfaces")
        #expect(!words.contains { $0.text == "open" }, "raw mis-hearing never reaches the engine")
    }

    // (a) A clean caption generated as "OpenAI" is not reverted to the raw "open eye" by a resync.
    @Test func cleanCorrectedCaptionIsNeverRevertedToRaw() {
        let cap = captionClip(id: "cap", start: 0, duration: 30, text: "OpenAI", generatedText: "OpenAI")
        let tl = timeline([Fixtures.audioTrack(clips: [source()]), Fixtures.videoTrack(clips: [cap])])
        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<30], trigger: "Trim Clip", fps: 30,
            policy: .preserve, wordSource: provider(openEyeCorrector(), source: source()), chunk: singleChunk)
        #expect(plan.replacements.allSatisfy { $0.clipId != "cap" }, "corrected clean clip needs no change")
        #expect(!plan.replacements.contains { $0.text.contains("open eye") }, "raw spelling never written back")
    }

    // (b) §5.2 glossary-add propagation: a clean clip still showing the raw text is corrected on resync.
    @Test func glossaryAddPropagatesCorrectionToCleanCaption() {
        let cap = captionClip(id: "cap", start: 0, duration: 30, text: "open eye", generatedText: "open eye")
        let tl = timeline([Fixtures.audioTrack(clips: [source()]), Fixtures.videoTrack(clips: [cap])])
        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<30], trigger: "glossary_add", fps: 30,
            policy: .preserve, wordSource: provider(openEyeCorrector(), source: source()), chunk: singleChunk)
        #expect(plan.replacements.first { $0.clipId == "cap" }?.text == "OpenAI")
    }

    // (c) glossary_remove: with the term gone the corrector is empty, so the clip reverts to raw text.
    @Test func glossaryRemoveRevertsCleanCaptionToRaw() {
        let cap = captionClip(id: "cap", start: 0, duration: 30, text: "OpenAI", generatedText: "OpenAI")
        let tl = timeline([Fixtures.audioTrack(clips: [source()]), Fixtures.videoTrack(clips: [cap])])
        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<30], trigger: "glossary_remove", fps: 30,
            policy: .preserve, wordSource: provider(GlossaryCorrector(terms: []), source: source()), chunk: singleChunk)
        #expect(plan.replacements.first { $0.clipId == "cap" }?.text == "open eye")
    }
}

// The REACTIVE resync path (not the tools) must chunk newly uncovered words using the project's
// caption-style segmentation, so a trim produces the same line breaks as add_captions/resync_captions.
@MainActor
@Suite struct CaptionResyncProfileSegmentationTests {
    @Test func reactiveResyncHonorsProfileSegmentation() throws {
        let pkg = FileManager.default.temporaryDirectory
            .appendingPathComponent("resync-seg-\(UUID().uuidString).palmier", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pkg) }
        // Project profile sets fixedChars; a sidecar write is hermetic (temp package).
        try CaptionStyleStore.writeLayer(["typography": ["segmentation": "fixedChars"]],
                                         at: #require(CaptionStyleStore.projectURL(package: pkg)))

        var cap = captionClip(id: "cap", start: 0, duration: 30, text: "开始", generatedText: "开始")
        cap.textStyle = TextStyle(fontSize: 12)   // small font so the short CJK clause fits one fixedChars line
        let e = EditorViewModel()
        e.projectURL = pkg
        e.timeline = timeline([Fixtures.videoTrack(clips: [cap])])
        // 开始 covers [0,30); the uncovered clause 你好。再见朋友 in [30,120) is what gets chunked.
        let src = FakeWordSource(words: [
            word("开", 0, 15), word("始", 15, 30),
            word("你", 30, 45), word("好", 45, 60), word("。", 60, 65),
            word("再", 65, 80), word("见", 80, 95), word("朋", 95, 110), word("友", 110, 120),
        ])
        e.captionWordSourceProvider = { _ in src }

        func createdTexts(_ segmentation: CaptionBuilder.Segmentation?) -> [String] {
            let report = e.runCaptionResync(spans: [0..<120], trigger: "test", dryRun: true, segmentation: segmentation)
            return (report?.created ?? []).map(\.text)
        }

        let profile = createdTexts(nil)         // reactive: no explicit arg → resolves fixedChars from the profile
        let fixed = createdTexts(.fixedChars)    // explicit fixedChars reference
        let natural = createdTexts(.natural)     // explicit natural reference

        #expect(!profile.isEmpty)
        #expect(profile == fixed)                // reactive honored the fixedChars profile
        #expect(fixed != natural)                // the input actually discriminates the two modes
    }
}

// A clean caption over a source whose transcript is not cached (cold cache after reopen, eviction,
// unmaterialised cloud) must be PRESERVED, not deleted — the empty word span is a missing read, not a
// speech cut. A genuinely-cached empty span still removes the caption (no over-preservation).
@MainActor
@Suite struct CaptionResyncColdCacheTests {
    @Test func uncachedRefPreservesCleanCaptionInsteadOfDeleting() {
        let caption = captionClip(id: "cap", start: 0, duration: 90, text: "开照片", generatedText: "开照片")
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [], uncached: ["m"])  // audio ref has no cached transcript

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<90], trigger: "glossary_promotion", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk)

        #expect(plan.removals.isEmpty, "a clean caption is not deleted when its transcript is uncached")
        #expect(!plan.report.removed.contains { $0.clipId == "cap" })
        #expect(plan.report.conflicts.contains { $0.clipId == "cap" && $0.reason.contains("transcript not cached") })
        #expect(plan.report.skippedRefs == ["m"])
    }

    @Test func cachedEmptySpanStillRemovesCleanCaption() {
        let caption = captionClip(id: "cap", start: 0, duration: 90, text: "开照片", generatedText: "开照片")
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [], uncached: [])  // transcript cached; span genuinely empty (speech cut)

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<90], trigger: "Trim Clip", fps: 30,
            policy: .preserve, wordSource: src, chunk: singleChunk)

        #expect(plan.removals == ["cap"], "a genuinely-empty cached span still removes the clean caption")
        #expect(plan.report.conflicts.isEmpty)
    }
}

// MARK: - Resync-visibility UI cluster (A1 toast, A3 resolve, A4 freeze, A5 promotion parity)

@MainActor
@Suite struct CaptionResyncToastDecisionTests {
    private func report(updated: Int = 0, removed: Int = 0, created: Int = 0, conflicts: Int = 0, retimed: Int = 0) -> CaptionResyncReport {
        var r = CaptionResyncReport(trigger: "t")
        r.updated = (0..<updated).map { .init(clipId: "u\($0)", before: "a", after: "b") }
        r.removed = (0..<removed).map { .init(clipId: "r\($0)", text: "x") }
        r.created = (0..<created).map { .init(clipId: "c\($0)", text: "y", startFrame: 0, endFrame: 30) }
        r.conflicts = (0..<conflicts).map { .init(clipId: "k\($0)", manualText: "m", newTranscript: "n") }
        r.retimed = (0..<retimed).map { .init(clipId: "t\($0)", beforeStart: 0, beforeEnd: 30, afterStart: 5, afterEnd: 30) }
        return r
    }

    @Test func emptyReportProducesNoToast() {
        #expect(report().uiToast == nil)
    }

    @Test func retimedOnlyProducesNoToast() {
        #expect(report(retimed: 3).uiToast == nil)   // boundary nudges are too noisy to surface
    }

    @Test func contentChangesToastAsSuccess() {
        let toast = report(updated: 3, removed: 1).uiToast
        #expect(toast?.message == "Captions resynced · 3 updated, 1 removed.")
        #expect(toast?.kind == .success)
    }

    @Test func createdCountsAsAdded() {
        #expect(report(created: 2).uiToast?.message == "Captions resynced · 2 added.")
    }

    @Test func conflictsOnlyToastAsWarning() {
        let toast = report(conflicts: 2).uiToast
        #expect(toast?.message == "2 captions kept manual text — see inspector.")
        #expect(toast?.kind == .warning)
    }

    @Test func singleConflictIsSingular() {
        #expect(report(conflicts: 1).uiToast?.message == "1 caption kept manual text — see inspector.")
    }

    @Test func contentPlusConflictsToastAsWarning() {
        let toast = report(updated: 1, conflicts: 2).uiToast
        #expect(toast?.message == "Captions resynced · 1 updated. 2 kept manual text.")
        #expect(toast?.kind == .warning)
    }
}

@MainActor
@Suite struct CaptionResyncToastPresentationTests {
    private func editor() -> EditorViewModel {
        let e = EditorViewModel()
        e.timeline = timeline([Fixtures.videoTrack(clips: [captionClip(id: "cap", start: 0, duration: 60, text: "x", generatedText: "x")])])
        return e
    }

    @Test func uiOriginReportFiresToastAndConsumes() {
        let e = editor()
        var r = CaptionResyncReport(trigger: "Trim Clip")
        r.updated = [.init(clipId: "cap", before: "a", after: "b")]
        e.lastResyncReport = r

        e.presentReactiveResyncToastIfNeeded()
        #expect(e.mediaPanelToast?.message == "Captions resynced · 1 updated.")
        #expect(e.lastResyncReport == nil)   // consumed, so it can't fire twice
    }

    @Test func agentConsumedReportProducesNoToast() {
        let e = editor()
        var r = CaptionResyncReport(trigger: "Move Clips (Agent)")
        r.updated = [.init(clipId: "cap", before: "a", after: "b")]
        e.lastResyncReport = r
        _ = e.takeResyncReport()   // the tool layer already consumed it for its delta

        e.presentReactiveResyncToastIfNeeded()
        #expect(e.mediaPanelToast == nil)
    }

    @Test func retimedOnlyReportProducesNoToastButConsumes() {
        let e = editor()
        var r = CaptionResyncReport(trigger: "Trim Clip")
        r.retimed = [.init(clipId: "cap", beforeStart: 0, beforeEnd: 30, afterStart: 5, afterEnd: 30)]
        e.lastResyncReport = r

        e.presentReactiveResyncToastIfNeeded()
        #expect(e.mediaPanelToast == nil)
        #expect(e.lastResyncReport == nil)
    }
}

@MainActor
@Suite struct CaptionConflictResolveTests {
    private func editorWithConflict(text: String, generatedText: String?, words: [WordTiming]) -> EditorViewModel {
        let e = EditorViewModel()
        let cap = captionClip(id: "cap", start: 0, duration: 60, text: text, generatedText: generatedText, conflict: true)
        e.timeline = timeline([
            Fixtures.videoTrack(clips: [cap]),
            Fixtures.audioTrack(clips: [Fixtures.clip(id: "audio", mediaRef: "m", mediaType: .audio, start: 0, duration: 60)]),
        ])
        e.captionWordSourceProvider = { _ in FakeWordSource(words: words) }
        return e
    }

    @Test func keepMineClearsFlagAndKeepsText() {
        let e = editorWithConflict(text: "my words", generatedText: nil, words: [word("real", 0, 30), word("text", 30, 60)])
        e.keepManualCaptionText(clipIds: ["cap"])
        let cap = e.clipFor(id: "cap")
        #expect(cap?.resyncConflict == nil)
        #expect(cap?.textContent == "my words")   // manual text untouched
    }

    @Test func useTranscriptReplacesTextAndClearsFlag() {
        let e = editorWithConflict(text: "my words", generatedText: nil, words: [word("real", 0, 30), word("text", 30, 60)])
        e.useTranscriptForCaptionConflicts(clipIds: ["cap"])
        let cap = e.clipFor(id: "cap")
        #expect(cap?.textContent == "real text")
        #expect(cap?.resyncConflict == nil)
    }

    @Test func resolveConsumesReportSoNoStrayToast() {
        let e = editorWithConflict(text: "my words", generatedText: nil, words: [word("real", 0, 30), word("text", 30, 60)])
        e.useTranscriptForCaptionConflicts(clipIds: ["cap"])
        #expect(e.lastResyncReport == nil)   // deliberate resolve is not an A1 reactive toast
    }

    @Test func resolveIgnoresUnflaggedClips() {
        let e = EditorViewModel()
        e.timeline = timeline([Fixtures.videoTrack(clips: [captionClip(id: "clean", start: 0, duration: 60, text: "keep", generatedText: "keep")])])
        e.captionWordSourceProvider = { _ in FakeWordSource(words: [word("other", 0, 60)]) }
        e.useTranscriptForCaptionConflicts(clipIds: ["clean"])
        #expect(e.clipFor(id: "clean")?.textContent == "keep")   // not flagged → untouched
    }
}

@MainActor
@Suite struct CaptionResyncExemptEngineTests {
    // A4: the engine honors resyncExempt by skipping the clip entirely — no replace, remove, or flag.
    @Test func exemptClipIsSkippedEntirely() {
        let caption = captionClip(id: "cap", start: 0, duration: 60, text: "frozen title", generatedText: "frozen title", exempt: true)
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [word("brand", 0, 30), word("new", 30, 60)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<60], trigger: "Trim Clip", fps: 30,
            policy: .overwrite, wordSource: src, chunk: singleChunk)

        #expect(!plan.hasWork)                                   // even overwrite leaves an exempt clip alone
        #expect(plan.report.isEmpty)
        #expect(!plan.replacements.contains { $0.clipId == "cap" })
        #expect(!plan.removals.contains("cap"))
        #expect(!plan.flagged.contains("cap"))
    }
}

@MainActor
@Suite("Caption inspector-edit promotion parity", .isolatedGlossaryRoot)
struct CaptionPromotionParityTests {
    private func projectDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("promote-\(UUID().uuidString).palmier", isDirectory: true)
    }

    private func harness(dir: URL) -> ToolHarness {
        var cap = captionClip(id: "cap", start: 0, duration: 60, text: "李娘娘", generatedText: nil)
        cap.mediaRef = "m"
        let h = ToolHarness(timeline: timeline([Fixtures.videoTrack(clips: [cap])]))
        h.editor.projectURL = dir
        h.editor.captionWordSourceProvider = { _ in FakeWordSource(words: [], uncached: ["m"]) }
        return h
    }

    // The inspector helper promotes the identical single-substitution the MCP path does (娘娘→嬢嬢),
    // marking the clip clean so later resyncs don't log a false conflict. §5.1
    @Test func inspectorEditPromotesLikeUpdateText() {
        let dir = projectDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = harness(dir: dir)

        let promotion = h.editor.promoteCaptionEditIfClean(old: "李娘娘", new: "李嬢嬢", clipId: "cap")
        #expect(promotion?.storedCanonical == "嬢嬢")
        #expect(promotion?.storedVariants == ["娘娘"])
        #expect(promotion?.canonical == "嬢嬢" && promotion?.variant == "娘娘")
        #expect(h.editor.clipFor(id: "cap")?.generatedText == "李嬢嬢")   // §5.1 clean-mark
    }

    @Test func inspectorWrapperFiresLearnedToastOnPromotion() {
        let dir = projectDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = harness(dir: dir)
        h.editor.commitClipProperty(clipId: "cap") { _ = $0.setCaptionContent("李嬢嬢") }

        h.editor.promoteInspectorCaptionEdit(old: "李娘娘", new: "李嬢嬢", clipId: "cap")
        #expect(h.editor.mediaPanelToast?.message == "Learned 嬢嬢 — future transcripts corrected.")
        #expect(h.editor.mediaPanelToast?.kind == .success)
        #expect(h.editor.lastResyncReport == nil)   // §5.2 report consumed, no stray A1 toast
    }

    @Test func nonPromotingEditStaysSilent() {
        let dir = projectDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = harness(dir: dir)
        // Scattered multi-region edit does not promote.
        h.editor.promoteInspectorCaptionEdit(old: "我们住的酒店是", new: "我们的酒店", clipId: "cap")
        #expect(h.editor.mediaPanelToast == nil)
        #expect(h.editor.clipFor(id: "cap")?.generatedText == nil)   // no clean-mark
    }

    @Test func ungroupedClipDoesNotPromote() {
        let dir = projectDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var loose = captionClip(id: "loose", start: 0, duration: 60, text: "李娘娘", generatedText: nil)
        loose.captionGroupId = nil   // a hand-placed title, not part of a caption group
        let h = ToolHarness(timeline: timeline([Fixtures.videoTrack(clips: [loose])]))
        h.editor.projectURL = dir
        #expect(h.editor.promoteCaptionEditIfClean(old: "李娘娘", new: "李嬢嬢", clipId: "loose") == nil)
    }

    // An edit already promoted via the inspector must not double-promote when the same content later
    // flows through MCP update_text: the clip is clean (old == new) so it never enters the edit set.
    @Test func noDoublePromotionAcrossInspectorThenMCP() async throws {
        let dir = projectDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = harness(dir: dir)
        h.editor.commitClipProperty(clipId: "cap") { _ = $0.setCaptionContent("李嬢嬢") }
        h.editor.promoteInspectorCaptionEdit(old: "李娘娘", new: "李嬢嬢", clipId: "cap")
        h.editor.mediaPanelToast = nil

        let json = try await h.runOK("update_text", args: [
            "entries": [["clipId": "cap", "content": "李嬢嬢"]],
        ]) as? [String: Any]
        #expect(json?["promoted"] == nil)   // same content → no edit → no second promotion
    }
}

@MainActor
@Suite struct CaptionConflictPolicyDefaultTests {
    // The default policy flags (sets resyncConflict) while keeping the manual text — so A2/A3 surface the
    // mismatch instead of it being silent, without any change to the "never silently overwrite" contract.
    @Test func defaultPolicyFlagsAndKeepsManualText() {
        #expect(CaptionConflictPolicy.default == .flag)
        let caption = captionClip(id: "cap", start: 0, duration: 90, text: "my fix", generatedText: "one two three")
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        let src = FakeWordSource(words: [word("one", 0, 45), word("two", 45, 90)])

        let plan = CaptionResyncEngine.plan(
            timeline: tl, triggerSpans: [0..<90], trigger: "Trim Clip", fps: 30,
            policy: .default, wordSource: src, chunk: singleChunk)

        #expect(plan.flagged == ["cap"])                            // marks the clip for review
        #expect(!plan.replacements.contains { $0.clipId == "cap" }) // manual text kept, not overwritten
        #expect(plan.report.conflicts.first?.manualText == "my fix")
    }

    // The agent delta is unchanged apart from the flag: flag and preserve emit an identical conflict report
    // for the same input — flag only additionally sets resyncConflict on the clip.
    @Test func flagAndPreserveEmitIdenticalReport() {
        let caption = captionClip(id: "cap", start: 0, duration: 90, text: "my fix", generatedText: "one two three")
        let tl = timeline([Fixtures.videoTrack(clips: [caption])])
        func plan(_ policy: CaptionConflictPolicy) -> CaptionResyncPlan {
            CaptionResyncEngine.plan(
                timeline: tl, triggerSpans: [0..<90], trigger: "t", fps: 30,
                policy: policy, wordSource: FakeWordSource(words: [word("one", 0, 45), word("two", 45, 90)]),
                chunk: singleChunk)
        }
        #expect(plan(.flag).report == plan(.preserve).report)   // same report → same agent payload
        #expect(plan(.flag).flagged == ["cap"])                 // flag's only extra effect
        #expect(plan(.preserve).flagged.isEmpty)
    }
}
