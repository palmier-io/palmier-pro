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
    struct Conflict: Equatable, Sendable { var clipId: String; var manualText: String; var newTranscript: String }

    var trigger: String
    var spans: [[Int]] = []            // [[lower, upper), …] — array form so it is Sendable/Codable-friendly
    var updated: [Updated] = []
    var removed: [Removed] = []
    var created: [Created] = []
    var conflicts: [Conflict] = []
    var skippedRefs: [String] = []

    var isEmpty: Bool { updated.isEmpty && removed.isEmpty && created.isEmpty && conflicts.isEmpty }
}

@MainActor
enum CaptionResyncEngine {
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
                resolveClip(clip, words: words, policy: policy, into: &plan, removed: &removedIds)
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
        _ clip: Clip, words: [WordTiming], policy: CaptionConflictPolicy,
        into plan: inout CaptionResyncPlan, removed: inout Set<String>
    ) {
        let clipWords = words.filter { $0.startFrame < clip.endFrame && $0.endFrame > clip.startFrame }
        let current = clip.textContent ?? ""

        guard !clipWords.isEmpty else {
            plan.removals.append(clip.id)
            removed.insert(clip.id)
            plan.report.removed.append(.init(clipId: clip.id, text: current))
            return
        }

        let newText = joinWords(clipWords)
        let newTimings = relativeTimings(clipWords, clipStart: clip.startFrame, duration: clip.durationFrames)

        if newText == current {
            // Match — no text change. Clear a stale conflict flag if the manual text now agrees.
            if clip.resyncConflict == true { plan.clearedFlags.append(clip.id) }
            return
        }

        let dirty = clip.generatedText != nil && clip.textContent != clip.generatedText
        if !dirty {
            // Clean, or unknown provenance (generatedText == nil). Both replace; unknown provenance is
            // additionally conflict-logged for visibility since we can't prove the text was generated.
            plan.replacements.append(.init(clipId: clip.id, text: newText, wordTimings: newTimings, generatedText: newText))
            plan.report.updated.append(.init(clipId: clip.id, before: current, after: newText))
            if clip.generatedText == nil {
                plan.report.conflicts.append(.init(clipId: clip.id, manualText: current, newTranscript: newText))
            }
            return
        }

        switch policy {
        case .overwrite:
            plan.replacements.append(.init(clipId: clip.id, text: newText, wordTimings: newTimings, generatedText: newText))
            plan.report.updated.append(.init(clipId: clip.id, before: current, after: newText))
        case .preserve:
            plan.report.conflicts.append(.init(clipId: clip.id, manualText: current, newTranscript: newText))
        case .flag:
            plan.flagged.append(clip.id)
            plan.report.conflicts.append(.init(clipId: clip.id, manualText: current, newTranscript: newText))
        }
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
            return WordTiming(text: w.text, startFrame: rs, endFrame: re)
        }
    }
}
