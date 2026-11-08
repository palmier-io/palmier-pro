import Foundation

extension ToolExecutor {
    /// Read-only whole-timeline check. Returns findings with stable ids, the tool that would fix
    /// each one, and an explicit pass when there is nothing wrong.
    func qcTimeline(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["severity"], path: "qc_timeline")
        let minimum: TimelineIssue.Severity
        if let raw = args.string("severity") {
            guard let parsed = TimelineIssue.Severity(rawValue: raw) else {
                throw ToolError("severity must be error or warning.")
            }
            minimum = parsed
        } else {
            minimum = .warning
        }
        let revision = editor.visualReviewRevision
        let checked = editor.timeline.tracks.reduce(0) { $0 + $1.clips.count }
        let found = TimelineQCAudit.audit(timeline: editor.timeline, editor: editor)
        let visualIdentity = try await editor.visualUniquenessReport()
        let encoded = try await Self.encodeQC(found: found, minimum: minimum, checked: checked, visualIdentity: visualIdentity)
        try Task.checkCancellation()
        guard editor.visualReviewRevision == revision else { throw VisualUniquenessValidationError.staleSnapshot }
        return .ok(encoded)
    }

    @concurrent
    private static func encodeQC(found: [TimelineIssue], minimum: TimelineIssue.Severity,
                                 checked: Int, visualIdentity: VisualUniquenessReport) async throws -> String {
        try Task.checkCancellation()
        let kept = found.filter { $0.severity.meets(minimum) }
        let counts = Dictionary(grouping: found, by: \.severity).mapValues(\.count)
        let payload: [String: Any] = [
            "pass": kept.isEmpty,
            "errorCount": counts[.error] ?? 0,
            "warningCount": counts[.warning] ?? 0,
            "checked": checked,
            "visualIdentity": visualIdentity.receipt,
            "issues": kept.map { issue -> [String: Any] in
                var entry: [String: Any] = [
                    "kind": issue.kind.rawValue,
                    "severity": issue.severity.rawValue,
                    "detail": issue.detail,
                ]
                if let start = issue.startFrame { entry["startFrame"] = start }
                if let end = issue.endFrame { entry["endFrame"] = end }
                if let track = issue.trackIndex { entry["trackIndex"] = track }
                if let clipId = issue.clipId { entry["clipId"] = clipId }
                if let mediaRef = issue.mediaRef { entry["mediaRef"] = mediaRef }
                if let fix = issue.fix { entry["fix"] = fix }
                return entry
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try Task.checkCancellation()
        return String(decoding: data, as: UTF8.self)
    }
}
