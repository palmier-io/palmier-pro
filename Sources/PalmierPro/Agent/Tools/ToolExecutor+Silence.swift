import Foundation

extension ToolExecutor {

    private static let removeSilenceAllowedKeys: Set<String> = [
        "clipId", "thresholdDb", "minSilenceDuration", "edgePadding",
    ]

    func removeSilence(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.removeSilenceAllowedKeys, path: "remove_silence")

        let clipId = try args.requireString("clipId")
        guard let loc = editor.findClip(id: clipId) else { throw ToolError("Clip not found: \(clipId)") }
        let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard clip.mediaType == .video || clip.mediaType == .audio else {
            throw ToolError("Clip \(clipId) is not an audio or video clip; it has no audio to scan.")
        }

        var config = SilenceConfig()
        if let db = args.double("thresholdDb") {
            guard db <= 0 else { throw ToolError("thresholdDb must be ≤ 0 (a dBFS level, e.g. -35).") }
            config.thresholdLinear = Float(pow(10.0, db / 20.0))
        }
        if let minDur = args.double("minSilenceDuration") {
            guard minDur > 0 else { throw ToolError("minSilenceDuration must be greater than 0 seconds.") }
            config.minSilenceDuration = minDur
        }
        if let pad = args.double("edgePadding") {
            guard pad >= 0 else { throw ToolError("edgePadding must be ≥ 0 seconds.") }
            config.edgePaddingSeconds = pad
        }

        let silences: [(start: Double, end: Double)]
        do {
            silences = try await editor.detectSilences(for: clip, config: config)
        } catch let error as SilenceRemovalError {
            throw ToolError(error.errorDescription ?? "Could not analyze the clip's audio.")
        }

        guard !silences.isEmpty else {
            let payload: [String: Any] = [
                "removedSilences": 0, "removedFrames": 0,
                "note": "No silences crossed the threshold. Lower thresholdDb (e.g. -30) or minSilenceDuration to catch more.",
            ]
            guard let json = Self.jsonString(payload) else { throw ToolError("Failed to encode result") }
            return .ok(json)
        }

        let removedFrames = editor.removeSilences(clip: clip, silences: silences, config: config)

        guard removedFrames > 0 else {
            throw ToolError("Detected \(silences.count) silence\(silences.count == 1 ? "" : "s") but none resolved to removable frames on the timeline.")
        }

        let payload: [String: Any] = [
            "removedSilences": silences.count,
            "removedFrames": removedFrames,
            "thresholdDb": Int((20.0 * log10(max(Double(config.thresholdLinear), 1e-6))).rounded()),
            "note": "Removed silent regions and closed the gaps. Re-read get_timeline or get_transcript before another edit.",
        ]
        guard let json = Self.jsonString(payload) else { throw ToolError("Failed to encode result") }
        return .ok(json)
    }
}
