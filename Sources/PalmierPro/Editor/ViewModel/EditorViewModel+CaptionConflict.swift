// Inspector-driven resolution of caption resync state: clear a conflict keeping manual text, replace it
// with the transcript, or freeze captions out of automatic resync. All undoable; all poke the timeline
// so the conflict badge redraws. §A3 / §A4

import Foundation

extension EditorViewModel {
    /// Clear the resync-conflict flag on these clips, keeping their current (manual) text. The clip stays
    /// dirty — only the review flag drops. Undoable; group-aware when the caller passes a whole group.
    func keepManualCaptionText(clipIds: [String]) {
        let flagged = clipIds.filter { clipFor(id: $0)?.resyncConflict == true }
        guard !flagged.isEmpty else { return }
        commitClipProperties(clipIds: flagged, actionName: "Keep Caption Text") { $0.resyncConflict = nil }
        mediaVisualCache.timelineView?.needsDisplay = true
    }

    /// Replace each flagged clip's text with the transcript the resync engine generates for its span and
    /// clear the flag — a deterministic, agent-free resolve. Reuses the engine under an overwrite policy
    /// scoped to exactly the flagged clips (half-open spans never pull in a track neighbor). Undoable.
    func useTranscriptForCaptionConflicts(clipIds: [String]) {
        let spans = clipIds
            .compactMap { clipFor(id: $0) }
            .filter { $0.resyncConflict == true }
            .map { $0.startFrame..<$0.endFrame }
        guard !spans.isEmpty else { return }
        undo.perform("Use Transcript") {
            _ = runCaptionResync(spans: spans, trigger: "resolve_conflict", policyOverride: .overwrite)
        }
        _ = takeResyncReport()  // deliberate resolve — don't let the A1 reactive-resync toast fire
        mediaVisualCache.timelineView?.needsDisplay = true
    }

    /// Set or clear `resyncExempt` ("Freeze captions") across these clips. Group resolution is the
    /// caller's — TextTab passes the whole caption group. Undoable.
    func setCaptionResyncExempt(clipIds: [String], exempt: Bool) {
        guard !clipIds.isEmpty else { return }
        commitClipProperties(clipIds: clipIds, actionName: exempt ? "Freeze Captions" : "Unfreeze Captions") {
            $0.resyncExempt = exempt ? true : nil
        }
    }
}
