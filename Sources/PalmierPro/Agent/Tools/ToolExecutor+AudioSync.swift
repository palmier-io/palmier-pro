import Foundation

extension ToolExecutor {
    private static let syncAudioAllowedKeys: Set<String> = [
        "referenceClipId", "targetClipId", "targetClipIds", "searchWindowSeconds", "minConfidence",
    ]

    func syncAudio(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.syncAudioAllowedKeys, path: "sync_audio")

        let referenceClipId = try args.requireString("referenceClipId")
        var targets = args.stringArray("targetClipIds")
        if let single = args.string("targetClipId") { targets.append(single) }
        guard !targets.isEmpty else { throw ToolError("sync_audio: provide targetClipId or targetClipIds.") }

        let searchWindow = args.double("searchWindowSeconds") ?? EditorViewModel.AudioSyncDefaults.searchWindowSeconds
        guard searchWindow > 0 else { throw ToolError("sync_audio: searchWindowSeconds must be > 0.") }

        let report = await editor.syncAudio(
            referenceClipId: referenceClipId,
            targetClipIds: targets,
            searchWindowSeconds: searchWindow,
            minConfidence: args.double("minConfidence") ?? EditorViewModel.AudioSyncDefaults.minConfidence
        )
        guard !report.synced.isEmpty else {
            throw ToolError("sync_audio: \(report.failures.first?.message ?? "no clips aligned")")
        }

        var payload: [String: Any] = [
            "referenceClipId": referenceClipId,
            "synced": report.synced.map {
                ["clipId": $0.clipId, "offsetFrames": $0.offsetFrames, "confidence": ($0.confidence * 1000).rounded() / 1000]
            },
        ]
        if !report.failures.isEmpty {
            payload["failed"] = report.failures.map { ["clipId": $0.clipId, "reason": $0.message] }
        }
        return .ok(Self.jsonString(payload) ?? "Synchronized \(report.synced.count) clip(s).")
    }
}
