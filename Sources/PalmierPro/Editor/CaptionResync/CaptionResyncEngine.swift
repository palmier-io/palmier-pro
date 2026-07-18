// CaptionResyncEngine — recomputes caption text/timings from cached transcripts (L2) after an
// audible-content edit and writes only caption clips (L3). Pure and provider-driven so it unit-tests
// with a synthetic timeline and a read-only word source; never touches asset transcripts or the cache.

import Foundation

/// How resync treats a manually-edited (dirty) caption clip whose transcript has since changed.
enum CaptionConflictPolicy: String, Codable, Sendable, CaseIterable {
    case preserve   // keep the manual text, record a conflict (default)
    case overwrite  // replace the manual text with the new transcript
    case flag       // keep the manual text and mark the clip for review

    static let `default`: CaptionConflictPolicy = .preserve
}

/// Read-only source of transcript words. The protocol exposes no write API, so an engine holding one
/// cannot mutate transcripts (L1) or the transcript cache (L2) — the L1/L2 isolation is enforced by type.
protocol CaptionWordSource {
    /// Transcript words audible on audible tracks within project-frame span [range), mapped to absolute
    /// project frames, sorted by start. Cache-only: assets without a cached transcript contribute nothing.
    func audibleWords(in range: Range<Int>) -> [WordTiming]
    /// Media refs overlapping [range) whose transcript was not cached, so they were skipped (not resynced).
    func uncachedRefs(in range: Range<Int>) -> [String]
}

/// What the engine decided; the VM applies it inside the trigger's undo transaction.
struct CaptionResyncPlan {
    struct Replacement: Equatable {
        var clipId: String
        var text: String
        var wordTimings: [WordTiming]
        var generatedText: String
        // Set only when a clean clip's boundaries were retimed to its word span; nil leaves them.
        var startFrame: Int?
        var durationFrames: Int?
    }
    var replacements: [Replacement] = []
    var removals: [String] = []
    var creations: [EditorViewModel.TextClipSpec] = []
    var flagged: [String] = []       // set resyncConflict = true
    var clearedFlags: [String] = []  // clear resyncConflict
    var report: CaptionResyncReport

    var hasWork: Bool {
        !replacements.isEmpty || !removals.isEmpty || !creations.isEmpty || !flagged.isEmpty || !clearedFlags.isEmpty
    }
}

/// User- and agent-facing summary of a resync pass.
struct CaptionResyncReport: Equatable, Sendable {
    struct Updated: Equatable, Sendable { var clipId: String; var before: String; var after: String }
    struct Removed: Equatable, Sendable { var clipId: String; var text: String }
    struct Created: Equatable, Sendable { var clipId: String?; var text: String; var startFrame: Int; var endFrame: Int }
    struct Conflict: Equatable, Sendable { var clipId: String; var manualText: String; var newTranscript: String; var reason: String = "" }
    struct Retimed: Equatable, Sendable { var clipId: String; var beforeStart: Int; var beforeEnd: Int; var afterStart: Int; var afterEnd: Int }

    var trigger: String
    var spans: [[Int]] = []            // [[lower, upper), …] — array form so it is Sendable/Codable-friendly
    var updated: [Updated] = []
    var removed: [Removed] = []
    var created: [Created] = []
    var conflicts: [Conflict] = []
    var retimed: [Retimed] = []
    var skippedRefs: [String] = []

    var isEmpty: Bool { updated.isEmpty && removed.isEmpty && created.isEmpty && conflicts.isEmpty && retimed.isEmpty && skippedRefs.isEmpty }
}

@MainActor
enum CaptionResyncEngine {
    /// A clean clip's boundary is only moved when its word span drifts more than this from the clip
    /// edge — smaller drifts are quantization noise and would churn the timeline for nothing.
    static let boundaryThreshold = 2

    /// Splits audible words (absolute project frames) into caption-sized phrase groups for newly
    /// uncovered spans. Injected so tests can substitute a trivial splitter for CaptionBuilder.
    typealias Chunker = (_ words: [WordTiming], _ maxWords: Int?) -> [[WordTiming]]

    static func plan(
        timeline: Timeline,
        triggerSpans: [Range<Int>],
        trigger: String,
        fps: Int,
        policy: CaptionConflictPolicy,
        wordSource: CaptionWordSource,
        chunk: Chunker
    ) -> CaptionResyncPlan {
        let spans = mergeSpans(triggerSpans)
        var report = CaptionResyncReport(trigger: trigger)
        report.spans = spans.map { [$0.lowerBound, $0.upperBound] }
        var plan = CaptionResyncPlan(report: report)
        guard !spans.isEmpty else { return plan }

        // Groups a user opted out of are never touched.
        let exemptGroups = exemptGroupIds(timeline)
        var skipped = Set<String>()

        for span in spans {
            let captionClips = captionClipsIntersecting(span, timeline: timeline, excludingGroups: exemptGroups)

            // Expand the word lookup to the extents of the caption clips touching this span, so a clip
            // that reaches past the edited region still recomputes from all of its own words — while
            // staying confined to the edited region (downstream, shifted captions are never queried).
            var lo = span.lowerBound, hi = span.upperBound
            for c in captionClips { lo = min(lo, c.startFrame); hi = max(hi, c.endFrame) }
            let words = wordSource.audibleWords(in: lo..<hi)
            for ref in wordSource.uncachedRefs(in: lo..<hi) where skipped.insert(ref).inserted {
                plan.report.skippedRefs.append(ref)
            }

            var removedIds = Set<String>()
            for clip in captionClips {
                // A ref with source clips overlapping this caption but no cached transcript means the word
                // set for this clip is absent or partial — not a genuine speech cut. Gate destructive
                // actions on it so a cold cache can't delete or shrink a good caption.
                let uncached = !wordSource.uncachedRefs(in: clip.startFrame..<clip.endFrame).isEmpty
                resolveClip(clip, words: words, policy: policy, uncached: uncached,
                            bounds: neighborBounds(for: clip, in: timeline), into: &plan, removed: &removedIds)
            }

            createUncovered(
                span: span, words: words, captionClips: captionClips, removedIds: removedIds,
                timeline: timeline, fps: fps, chunk: chunk, into: &plan
            )
        }
        return plan
    }

    // MARK: - Per-clip REPLACE / REMOVE / conflict

    private static func resolveClip(
        _ clip: Clip, words: [WordTiming], policy: CaptionConflictPolicy, uncached: Bool,
        bounds: (lower: Int, upper: Int), into plan: inout CaptionResyncPlan, removed: inout Set<String>
    ) {
        let clipWords = words.filter { $0.startFrame < clip.endFrame && $0.endFrame > clip.startFrame }
        let current = clip.textContent ?? ""
        // Clean only when provably transcript-generated and untouched; nil generatedText counts as dirty.
        let clean = clip.generatedText != nil && clip.textContent == clip.generatedText

        // Cold cache: a clean caption is rebuilt from cached words, so an uncached overlapping ref would
        // either DELETE it (empty span read as a speech cut) or shrink it (partial words). Preserve it and
        // log why instead — the correction survives a reopen/eviction/unmaterialised-cloud read until the
        // transcript is available again. Dirty clips fall through to policy; cached clips are unaffected.
        if clean, uncached {
            plan.report.conflicts.append(.init(
                clipId: clip.id, manualText: current, newTranscript: current,
                reason: "transcript not cached — resync skipped; re-open the transcript or run resync_captions after transcription"))
            return
        }

        // Empty span: auto-remove only clean generated captions; custom/edited ones follow policy.
        guard !clipWords.isEmpty else {
            if clean { remove(clip, current: current, into: &plan, removed: &removed); return }
            switch policy {
            case .overwrite: remove(clip, current: current, into: &plan, removed: &removed)
            case .preserve: plan.report.conflicts.append(conflict(clip, current: current, newText: ""))
            case .flag:
                plan.flagged.append(clip.id)
                plan.report.conflicts.append(conflict(clip, current: current, newText: ""))
            }
            return
        }

        let newText = joinWords(clipWords)
        // Boundary retiming (onset rollback / trailing-silence tighten) is confined to clean clips.
        let retiming = clean ? retimedBounds(clip, clipWords: clipWords, bounds: bounds) : nil
        let effStart = retiming?.startFrame ?? clip.startFrame
        let effDuration = retiming?.durationFrames ?? clip.durationFrames
        let newTimings = relativeTimings(clipWords, clipStart: effStart, duration: effDuration)

        if newText == current {
            // Text matches, but a clean clip's boundaries may still have drifted (e.g. onset rollback).
            if let retiming { appendReplacement(clip, text: newText, timings: newTimings, retiming: retiming, into: &plan) }
            if clip.resyncConflict == true { plan.clearedFlags.append(clip.id) }
            return
        }

        if clean {
            appendReplacement(clip, text: newText, timings: newTimings, retiming: retiming, into: &plan)
            plan.report.updated.append(.init(clipId: clip.id, before: current, after: newText))
            return
        }

        switch policy {
        case .overwrite:
            plan.replacements.append(.init(clipId: clip.id, text: newText, wordTimings: newTimings, generatedText: newText))
            plan.report.updated.append(.init(clipId: clip.id, before: current, after: newText))
        case .preserve:
            plan.report.conflicts.append(conflict(clip, current: current, newText: newText))
        case .flag:
            plan.flagged.append(clip.id)
            plan.report.conflicts.append(conflict(clip, current: current, newText: newText))
        }
    }

    private struct Retiming { var startFrame: Int; var durationFrames: Int }

    private static func appendReplacement(
        _ clip: Clip, text: String, timings: [WordTiming], retiming: Retiming?, into plan: inout CaptionResyncPlan
    ) {
        var r = CaptionResyncPlan.Replacement(clipId: clip.id, text: text, wordTimings: timings, generatedText: text)
        if let retiming {
            r.startFrame = retiming.startFrame
            r.durationFrames = retiming.durationFrames
            plan.report.retimed.append(.init(
                clipId: clip.id, beforeStart: clip.startFrame, beforeEnd: clip.endFrame,
                afterStart: retiming.startFrame, afterEnd: retiming.startFrame + retiming.durationFrames))
        }
        plan.replacements.append(r)
    }

    /// New boundaries for a clean clip whose word span drifted past the threshold, clamped so it never
    /// overlaps a track neighbor. nil when nothing moved beyond the churn threshold or there is no room.
    private static func retimedBounds(_ clip: Clip, clipWords: [WordTiming], bounds: (lower: Int, upper: Int)) -> Retiming? {
        guard let first = clipWords.first, let last = clipWords.last else { return nil }
        let lower = max(0, bounds.lower)
        let upper = bounds.upper
        guard lower < upper else { return nil }
        let spanStart = min(max(first.startFrame, lower), upper - 1)
        let spanEnd = max(min(last.endFrame, upper), lower + 1)
        guard spanStart < spanEnd else { return nil }
        let start = abs(spanStart - clip.startFrame) > boundaryThreshold ? spanStart : clip.startFrame
        let end = abs(spanEnd - clip.endFrame) > boundaryThreshold ? spanEnd : clip.endFrame
        guard (start != clip.startFrame || end != clip.endFrame), end > start else { return nil }
        return Retiming(startFrame: start, durationFrames: end - start)
    }

    /// Frame window a clip may grow into without overlapping other clips on its track. Track clips never
    /// overlap, so every other clip is wholly before (bounds the lower edge) or after (bounds the upper).
    private static func neighborBounds(for clip: Clip, in timeline: Timeline) -> (lower: Int, upper: Int) {
        guard let track = timeline.tracks.first(where: { t in t.clips.contains { $0.id == clip.id } }) else {
            return (0, Int.max)
        }
        var lower = 0
        var upper = Int.max
        for other in track.clips where other.id != clip.id {
            if other.startFrame < clip.startFrame { lower = max(lower, other.endFrame) }
            else if other.startFrame > clip.startFrame { upper = min(upper, other.startFrame) }
        }
        return (lower, upper)
    }

    private static func remove(_ clip: Clip, current: String, into plan: inout CaptionResyncPlan, removed: inout Set<String>) {
        plan.removals.append(clip.id)
        removed.insert(clip.id)
        plan.report.removed.append(.init(clipId: clip.id, text: current))
    }

    private static func conflict(_ clip: Clip, current: String, newText: String) -> CaptionResyncReport.Conflict {
        let reason = clip.generatedText == nil
            ? "unknown provenance — predates provenance tracking or hand-placed; resync_captions onManualEdits:overwrite to rebuild"
            : "manual edit preserved; resync_captions onManualEdits:overwrite to rebuild"
        return .init(clipId: clip.id, manualText: current, newTranscript: newText, reason: reason)
    }

    // MARK: - CREATE for newly uncovered speech

    private static func createUncovered(
        span: Range<Int>, words: [WordTiming], captionClips: [Clip], removedIds: Set<String>,
        timeline: Timeline, fps: Int, chunk: Chunker, into plan: inout CaptionResyncPlan
    ) {
        // Only create when a single caption group owns this region — otherwise the target group is ambiguous.
        let groups = Set(captionClips.compactMap(\.captionGroupId))
        guard groups.count == 1, let groupId = groups.first else { return }
        let groupClips = captionClips.filter { $0.captionGroupId == groupId }
        guard let trackIndex = trackIndex(ofGroup: groupId, timeline: timeline),
              let modal = groupClips.first else { return }

        let covered = groupClips.filter { !removedIds.contains($0.id) }.map { $0.startFrame..<$0.endFrame }
        let uncovered = words.filter { w in
            let mid = (w.startFrame + w.endFrame) / 2
            guard mid >= span.lowerBound, mid < span.upperBound else { return false }
            return !covered.contains { $0.contains(mid) }
        }
        guard !uncovered.isEmpty else { return }

        let maxWords = inferredMaxWords(groupClips)
        let style = modal.textStyle ?? TextStyle()
        let animation = modal.textAnimation
        for group in chunk(uncovered, maxWords) {
            guard let first = group.first, let last = group.last, last.endFrame > first.startFrame else { continue }
            let start = first.startFrame
            let duration = max(1, last.endFrame - start)
            let text = joinWords(group)
            let spec = EditorViewModel.TextClipSpec(
                trackIndex: trackIndex,
                startFrame: start,
                durationFrames: duration,
                content: text,
                style: style,
                transform: nil,
                captionGroupId: groupId,
                words: relativeTimings(group, clipStart: start, duration: duration),
                animation: animation,
                generatedText: text
            )
            plan.creations.append(spec)
            plan.report.created.append(.init(clipId: nil, text: text, startFrame: start, endFrame: start + duration))
        }
    }

    // MARK: - Helpers

    static func mergeSpans(_ spans: [Range<Int>]) -> [Range<Int>] {
        let valid = spans.filter { $0.lowerBound < $0.upperBound }.sorted { $0.lowerBound < $1.lowerBound }
        guard var cur = valid.first else { return [] }
        var out: [Range<Int>] = []
        for s in valid.dropFirst() {
            if s.lowerBound <= cur.upperBound {
                cur = cur.lowerBound..<max(cur.upperBound, s.upperBound)
            } else {
                out.append(cur); cur = s
            }
        }
        out.append(cur)
        return out
    }

    private static func captionClipsIntersecting(_ span: Range<Int>, timeline: Timeline, excludingGroups exempt: Set<String>) -> [Clip] {
        timeline.tracks.flatMap(\.clips).filter { clip in
            guard clip.mediaType == .text, let g = clip.captionGroupId, !exempt.contains(g) else { return false }
            return clip.startFrame < span.upperBound && clip.endFrame > span.lowerBound
        }
    }

    private static func exemptGroupIds(_ timeline: Timeline) -> Set<String> {
        Set(timeline.tracks.flatMap(\.clips)
            .filter { $0.mediaType == .text && $0.resyncExempt == true }
            .compactMap(\.captionGroupId))
    }

    private static func trackIndex(ofGroup groupId: String, timeline: Timeline) -> Int? {
        timeline.tracks.firstIndex { track in
            track.clips.contains { $0.captionGroupId == groupId && $0.mediaType == .text }
        }
    }

    private static func inferredMaxWords(_ clips: [Clip]) -> Int? {
        let counts = clips.map { ($0.textContent ?? "").split(whereSeparator: \.isWhitespace).count }.filter { $0 > 0 }
        return counts.max()
    }

    static func joinWords(_ words: [WordTiming]) -> String {
        words.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Absolute-frame words → clip-relative timings clamped to the clip's duration.
    static func relativeTimings(_ words: [WordTiming], clipStart: Int, duration: Int) -> [WordTiming] {
        words.compactMap { w in
            let rs = min(max(0, w.startFrame - clipStart), duration)
            let re = min(max(rs, w.endFrame - clipStart), duration)
            guard re > rs else { return nil }
            return WordTiming(text: w.text, startFrame: rs, endFrame: re, aligned: w.aligned)
        }
    }
}
