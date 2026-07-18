// EditorViewModel+CaptionResync — reactive glue between timeline mutations and CaptionResyncEngine.
// Diffs before/after occupancy on audible tracks into affected spans, runs the engine cache-only,
// and applies its plan inside the trigger's undo transaction so one undo reverts trigger + resync.

import Foundation

extension EditorViewModel {
    // MARK: - Trigger entry points

    /// Reactive resync after a `withTimelineSwap` mutation. Runs inside `work` (registration disabled),
    /// so its writes land in the same before→after swap the caller registers.
    func resyncCaptionsAfterSwap(before: Timeline, trigger: String) {
        guard shouldResync else { return }
        let spans = captionResyncAffectedSpans(before: before, after: timeline)
        runCaptionResync(spans: spans, trigger: trigger)
    }

    /// Reactive resync after a plain (non-ripple) trim, whose geometry gives the affected span directly.
    func resyncCaptionsAfterTrim(before: Range<Int>, after: Range<Int>, trigger: String) {
        guard shouldResync else { return }
        runCaptionResync(spans: [before, after], trigger: trigger)
    }

    /// A glossary change re-derives exactly the caption clips that mention the term — global
    /// selection, cost proportional to occurrences, never the whole timeline. §5.2
    func resyncCaptionsForGlossaryTerm(strings: [String], trigger: String) {
        guard shouldResync else { return }
        let needles = strings.filter { !$0.isEmpty }
        guard !needles.isEmpty else { return }
        var spans: [Range<Int>] = []
        for track in timeline.tracks {
            for clip in track.clips where clip.mediaType == .text && clip.captionGroupId != nil {
                guard let text = clip.textContent,
                      needles.contains(where: { text.contains($0) }),
                      clip.endFrame > clip.startFrame else { continue }
                spans.append(clip.startFrame..<clip.endFrame)
            }
        }
        guard !spans.isEmpty else { return }
        undo.perform("Resync Captions (Glossary)") {
            _ = runCaptionResync(spans: spans, trigger: trigger)
        }
    }

    private var shouldResync: Bool {
        !isResyncingCaptions
            && !undo.isUndoingOrRedoing
            && timeline.tracks.contains { track in
                track.clips.contains { $0.mediaType == .text && $0.captionGroupId != nil }
            }
    }

    // MARK: - Core

    /// Build the plan and apply it. Stashes the report on `lastResyncReport` for the agent tool layer.
    @discardableResult
    func runCaptionResync(spans: [Range<Int>], trigger: String, dryRun: Bool = false, policyOverride: CaptionConflictPolicy? = nil, segmentation: CaptionBuilder.Segmentation = .default) -> CaptionResyncReport? {
        let merged = CaptionResyncEngine.mergeSpans(spans)
        guard !merged.isEmpty else { return nil }
        let source = captionWordSourceProvider?(self) ?? TimelineTranscriptProvider(editor: self)
        let plan = CaptionResyncEngine.plan(
            timeline: timeline,
            triggerSpans: merged,
            trigger: trigger,
            fps: timeline.fps,
            policy: policyOverride ?? captionConflictPolicy,
            wordSource: source,
            chunk: captionResyncChunker(segmentation: segmentation)
        )
        guard !dryRun else { return plan.report }
        guard plan.hasWork else {
            lastResyncReport = plan.report.isEmpty ? nil : plan.report
            return plan.report
        }
        let report = applyResyncPlan(plan)
        lastResyncReport = report
        return report
    }

    /// Reads and clears the stashed report so a tool wrapper reports each resync at most once.
    func takeResyncReport() -> CaptionResyncReport? {
        defer { lastResyncReport = nil }
        return lastResyncReport
    }

    // MARK: - Apply

    @discardableResult
    private func applyResyncPlan(_ plan: CaptionResyncPlan) -> CaptionResyncReport {
        isResyncingCaptions = true
        defer { isResyncingCaptions = false }
        var report = plan.report

        let before = timeline
        let removals = Set(plan.removals)
        if !removals.isEmpty {
            for ti in timeline.tracks.indices {
                timeline.tracks[ti].clips.removeAll { removals.contains($0.id) }
            }
        }
        for r in plan.replacements {
            guard let loc = findClip(id: r.clipId) else { continue }
            if let s = r.startFrame { timeline.tracks[loc.trackIndex].clips[loc.clipIndex].startFrame = s }
            if let d = r.durationFrames { timeline.tracks[loc.trackIndex].clips[loc.clipIndex].durationFrames = d }
            timeline.tracks[loc.trackIndex].clips[loc.clipIndex].textContent = r.text
            timeline.tracks[loc.trackIndex].clips[loc.clipIndex].wordTimings = r.wordTimings.isEmpty ? nil : r.wordTimings
            timeline.tracks[loc.trackIndex].clips[loc.clipIndex].generatedText = r.generatedText
            timeline.tracks[loc.trackIndex].clips[loc.clipIndex].resyncConflict = nil
        }
        for id in plan.flagged {
            guard let loc = findClip(id: id) else { continue }
            timeline.tracks[loc.trackIndex].clips[loc.clipIndex].resyncConflict = true
        }
        for id in plan.clearedFlags {
            guard let loc = findClip(id: id) else { continue }
            timeline.tracks[loc.trackIndex].clips[loc.clipIndex].resyncConflict = nil
        }
        if !plan.creations.isEmpty {
            let created = placeTextClips(plan.creations, clearExistingRegions: false, refreshVisuals: false)
            for (i, id) in created.enumerated() where i < report.created.count {
                report.created[i].clipId = id
            }
        }

        guard before != timeline else { return report }
        // No-op when registration is disabled (withTimelineSwap path — captured by its own swap);
        // joins the active group when enabled (trim path), so undo reverts trigger + resync together.
        registerTimelineSwap(undoState: before, redoState: timeline, actionName: "Resync Captions")
        videoEngine?.refreshVisuals()
        return report
    }

    // MARK: - Affected span diff

    private struct AudibleSig: Equatable {
        let mediaRef: String
        let trimStartFrame: Int
        let trimEndFrame: Int
        let speed: Double
        let durationFrames: Int
    }

    /// Ranges of the timeline whose audible content changed. A clip that only shifted is excluded as a
    /// pure ripple ONLY when the captions above it shifted by the same delta — i.e. they stayed aligned
    /// with it. Captions left behind (a block-swap, a stationary caption) or captions the clip landed
    /// under (a move onto occupied territory) fail that test, so the clip is resynced. The rule is
    /// content-grounded and order-independent, so a two-direction swap resolves the same way every run.
    func captionResyncAffectedSpans(before: Timeline, after: Timeline) -> [Range<Int>] {
        let b = audibleClips(before)
        let a = audibleClips(after)
        let beforeCaps = captionSpans(before)
        let afterCaps = captionSpans(after)
        var spans: [Range<Int>] = []

        for id in Set(b.keys).union(a.keys) {
            switch (b[id], a[id]) {
            case let (old?, nil):
                spans.append(old.range)
            case let (nil, new?):
                spans.append(new.range)
            case let (old?, new?):
                if old.sig != new.sig {
                    spans.append(old.range)
                    spans.append(new.range)
                } else if old.range.lowerBound != new.range.lowerBound,
                          !captionsMoved(with: old.range, to: new.range, beforeCaps: beforeCaps, afterCaps: afterCaps) {
                    spans.append(old.range)
                    spans.append(new.range)
                }
            case (nil, nil):
                break
            }
        }
        return spans
    }

    private struct CaptionKey: Equatable, Comparable {
        let id: String
        let relStart: Int
        let relEnd: Int
        static func < (l: CaptionKey, r: CaptionKey) -> Bool {
            (l.relStart, l.relEnd, l.id) < (r.relStart, r.relEnd, r.id)
        }
    }

    /// True iff the caption clips overlapping `oldSpan`, translated by the shift, exactly match those
    /// overlapping `newSpan` — same caption id at the same offset relative to the clip.
    private func captionsMoved(
        with oldSpan: Range<Int>, to newSpan: Range<Int>,
        beforeCaps: [(id: String, range: Range<Int>)], afterCaps: [(id: String, range: Range<Int>)]
    ) -> Bool {
        captionKeys(overlapping: oldSpan, in: beforeCaps) == captionKeys(overlapping: newSpan, in: afterCaps)
    }

    private func captionKeys(overlapping span: Range<Int>, in caps: [(id: String, range: Range<Int>)]) -> [CaptionKey] {
        caps
            .filter { $0.range.lowerBound < span.upperBound && $0.range.upperBound > span.lowerBound }
            .map { CaptionKey(id: $0.id, relStart: $0.range.lowerBound - span.lowerBound, relEnd: $0.range.upperBound - span.lowerBound) }
            .sorted()
    }

    private func captionSpans(_ timeline: Timeline) -> [(id: String, range: Range<Int>)] {
        timeline.tracks.flatMap(\.clips)
            .filter { $0.mediaType == .text && $0.captionGroupId != nil }
            .map { ($0.id, $0.startFrame..<$0.endFrame) }
    }

    private func audibleClips(_ timeline: Timeline) -> [String: (range: Range<Int>, sig: AudibleSig)] {
        var out: [String: (range: Range<Int>, sig: AudibleSig)] = [:]
        for track in timeline.tracks {
            for clip in track.clips where isAudibleSource(clip) {
                out[clip.id] = (
                    clip.startFrame..<clip.endFrame,
                    AudibleSig(
                        mediaRef: clip.mediaRef,
                        trimStartFrame: clip.trimStartFrame,
                        trimEndFrame: clip.trimEndFrame,
                        speed: clip.speed,
                        durationFrames: clip.durationFrames
                    )
                )
            }
        }
        return out
    }

    func isAudibleSource(_ clip: Clip) -> Bool {
        switch clip.mediaType {
        case .audio: return true
        case .video: return mediaAssetsById[clip.mediaRef]?.hasAudio ?? true
        default: return false
        }
    }

    // MARK: - Chunker (production wraps CaptionBuilder)

    /// Splits newly uncovered words into caption-sized groups using the same phrase logic as generation,
    /// so created clips respect the group's visual fit and implied maxWords.
    func captionResyncChunker(segmentation: CaptionBuilder.Segmentation = .default) -> CaptionResyncEngine.Chunker {
        let fps = Double(timeline.fps)
        let style = captionResyncModalStyle()
        return { [weak self] words, maxWords in
            guard let self, !words.isEmpty, fps > 0 else { return words.isEmpty ? [] : [words] }
            let synthetic = words.map {
                TranscriptionWord(text: $0.text, start: Double($0.startFrame) / fps, end: Double($0.endFrame) / fps)
            }
            let phrases = CaptionBuilder.phrases(
                fromTimedWords: synthetic,
                fits: { self.captionLineFits($0, style: style) },
                maxWords: maxWords,
                minDuration: AppTheme.Caption.minDisplayDuration,
                segmentation: segmentation
            )
            guard !phrases.isEmpty else { return [words] }
            var out: [[WordTiming]] = []
            var i = 0
            for phrase in phrases {
                let n = max(phrase.words.count, 1)
                let group = Array(words[i..<min(i + n, words.count)])
                if !group.isEmpty { out.append(group) }
                i += n
            }
            if i < words.count { out.append(Array(words[i...])) }
            return out
        }
    }

    private func captionResyncModalStyle() -> TextStyle {
        timeline.tracks.flatMap(\.clips)
            .first { $0.mediaType == .text && $0.captionGroupId != nil }?
            .textStyle ?? TextStyle()
    }
}
