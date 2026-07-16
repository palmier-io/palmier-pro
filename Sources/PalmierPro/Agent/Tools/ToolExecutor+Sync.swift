import Foundation

extension ToolExecutor {
    private static let syncClipsAllowedKeys: Set<String> = [
        "referenceClipId", "targetClipId", "targetClipIds", "mode", "searchWindowSeconds", "minConfidence",
    ]

    func syncClips(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.syncClipsAllowedKeys, path: "sync_clips")

        let referenceClipId = try args.requireString("referenceClipId")
        var targets = args.stringArray("targetClipIds")
        if let single = args.string("targetClipId") { targets.append(single) }
        guard !targets.isEmpty else { throw ToolError("sync_clips: provide targetClipId or targetClipIds.") }
        if (targets + [referenceClipId]).contains(where: { editor.clipFor(id: $0)?.multicamGroupId != nil }) {
            throw ToolError("sync_clips: multicam clips are already aligned by their group's sync maps — re-syncing would move them out of the group.")
        }

        var mode = EditorViewModel.SyncMode.auto
        if let raw = args.string("mode") {
            guard let parsed = EditorViewModel.SyncMode(rawValue: raw) else {
                throw ToolError("sync_clips: mode must be auto, audio, or timecode.")
            }
            mode = parsed
        }
        let searchWindow = args.double("searchWindowSeconds") ?? EditorViewModel.SyncDefaults.searchWindowSeconds
        guard searchWindow > 0 else { throw ToolError("sync_clips: searchWindowSeconds must be > 0.") }

        let snapshot = timelineSnapshot(editor)
        let report = try await editor.syncClips(
            referenceClipId: referenceClipId,
            targetClipIds: targets,
            mode: mode,
            searchWindowSeconds: searchWindow,
            minConfidence: args.double("minConfidence") ?? EditorViewModel.SyncDefaults.minConfidence,
            applying: { mutation in
                editor.undo.perform("Synchronize Clips (Agent)", mutation)
            }
        )
        guard !report.synced.isEmpty else {
            throw ToolError("sync_clips: \(report.failures.first?.message ?? "no clips aligned")")
        }

        var extra: [String: Any] = [
            "referenceClipId": referenceClipId,
            "synced": report.synced.map {
                ["clipId": $0.clipId, "offsetFrames": $0.offsetFrames,
                 "confidence": ($0.confidence * 1000).rounded() / 1000, "method": $0.method.rawValue]
            },
        ]
        if report.shiftedFrames > 0 { extra["shiftedFrames"] = report.shiftedFrames }
        if !report.failures.isEmpty {
            extra["failed"] = report.failures.map { ["clipId": $0.clipId, "reason": $0.message] }
        }
        return mutationResult(editor, since: snapshot, touched: report.synced.map(\.clipId), extra: extra)
    }
}
