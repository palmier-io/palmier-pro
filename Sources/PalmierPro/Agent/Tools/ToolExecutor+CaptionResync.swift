// ToolExecutor+CaptionResync — the resync_captions escape hatch. Rebuilds caption text from the
// cached transcript for a group or span using the same engine as the reactive triggers; dryRun
// reports what would change without mutating. Also serializes CaptionResyncReport for tool payloads.

import Foundation

extension ToolExecutor {
    static let resyncCaptionsAllowedKeys: Set<String> = ["captionGroupId", "startFrame", "endFrame", "dryRun", "onManualEdits"]

    func resyncCaptions(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.resyncCaptionsAllowedKeys, path: "resync_captions")

        let dryRun = args["dryRun"] as? Bool ?? false
        let policyOverride = try parseConflictPolicy(args.string("onManualEdits"))

        // Resolve the spans to rebuild: an explicit group, an explicit range, their intersection,
        // or — when neither is given — every caption group in the project.
        let groupId = args.string("captionGroupId")
        let rangeStart = args["startFrame"] as? Int
        let rangeEnd = args["endFrame"] as? Int
        if let s = rangeStart, let e = rangeEnd, e <= s {
            throw ToolError("resync_captions: endFrame must be greater than startFrame")
        }

        var spans: [Range<Int>] = []
        if let groupId {
            let ids = editor.captionGroupTextClipIds(groupId: groupId)
            guard !ids.isEmpty else { throw ToolError("No caption clips found for captionGroupId: \(groupId)") }
            let clips = ids.compactMap { editor.findClip(id: $0).map { editor.timeline.tracks[$0.trackIndex].clips[$0.clipIndex] } }
            if let lo = clips.map(\.startFrame).min(), let hi = clips.map(\.endFrame).max(), hi > lo {
                spans.append(lo..<hi)
            }
        } else if let s = rangeStart, let e = rangeEnd {
            spans.append(s..<e)
        } else {
            let groups = Set(editor.timeline.tracks.flatMap(\.clips)
                .filter { $0.mediaType == .text }.compactMap(\.captionGroupId))
            for g in groups {
                let clips = editor.captionGroupTextClipIds(groupId: g)
                    .compactMap { editor.findClip(id: $0).map { editor.timeline.tracks[$0.trackIndex].clips[$0.clipIndex] } }
                if let lo = clips.map(\.startFrame).min(), let hi = clips.map(\.endFrame).max(), hi > lo {
                    spans.append(lo..<hi)
                }
            }
        }
        // Clip the resolved spans to the requested window when both a group and a range are given.
        if groupId != nil, let s = rangeStart, let e = rangeEnd {
            spans = spans.compactMap { span in
                let lo = max(span.lowerBound, s), hi = min(span.upperBound, e)
                return lo < hi ? lo..<hi : nil
            }
        }
        guard !spans.isEmpty else { throw ToolError("resync_captions: nothing to resync in the requested range") }

        if dryRun {
            let report = editor.runCaptionResync(spans: spans, trigger: "resync_captions", dryRun: true, policyOverride: policyOverride)
            let payload: [String: Any] = ["dryRun": true, "captionResync": report?.agentPayload ?? [:]]
            return .ok(Self.jsonString(payload) ?? "{}")
        }

        let snapshot = timelineSnapshot(editor)
        editor.undo.perform("Resync Captions") {
            editor.runCaptionResync(spans: spans, trigger: "resync_captions", policyOverride: policyOverride)
        }
        return mutationResult(editor, since: snapshot)
    }

    private func parseConflictPolicy(_ raw: String?) throws -> CaptionConflictPolicy? {
        guard let raw else { return nil }
        guard let policy = CaptionConflictPolicy(rawValue: raw) else {
            throw ToolError("resync_captions.onManualEdits must be one of: preserve, overwrite, flag")
        }
        return policy
    }
}

extension CaptionResyncReport {
    /// Compact dictionary for MCP payloads.
    var agentPayload: [String: Any] {
        var out: [String: Any] = ["trigger": trigger]
        if !spans.isEmpty { out["spans"] = spans }
        if !updated.isEmpty { out["updated"] = updated.map { ["clipId": $0.clipId, "before": $0.before, "after": $0.after] } }
        if !removed.isEmpty { out["removed"] = removed.map { ["clipId": $0.clipId, "text": $0.text] } }
        if !created.isEmpty {
            out["created"] = created.map { c -> [String: Any] in
                var row: [String: Any] = ["text": c.text, "startFrame": c.startFrame, "endFrame": c.endFrame]
                if let id = c.clipId { row["clipId"] = id }
                return row
            }
        }
        if !conflicts.isEmpty {
            out["conflicts"] = conflicts.map { ["clipId": $0.clipId, "manualText": $0.manualText, "newTranscript": $0.newTranscript] }
        }
        if !skippedRefs.isEmpty { out["skippedNoTranscript"] = skippedRefs }
        return out
    }
}
