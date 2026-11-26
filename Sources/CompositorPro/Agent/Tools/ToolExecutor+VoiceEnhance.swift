import Foundation

extension ToolExecutor {
    fileprivate struct DebreatheAudioInput: DecodableToolArgs {
        let clipIds: [String]
        let strength: Double?
        let enabled: Bool?
        static let allowedKeys: Set<String> = ["clipIds", "strength", "enabled"]
    }

    func debreatheAudio(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: DebreatheAudioInput = try decodeToolArgs(args, path: "debreath_audio")
        guard !input.clipIds.isEmpty else { throw ToolError("clipIds is empty.") }
        if let s = input.strength, !(0...1).contains(s) {
            throw ToolError("strength must be 0–1 (got \(s))")
        }
        for id in input.clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            guard clip.mediaType == .audio else {
                throw ToolError("Clip \(id) is a \(clip.mediaType.rawValue) clip; debreath_audio needs an audio clip.")
            }
        }

        let enabled = input.enabled ?? true
        let snapshot = timelineSnapshot(editor)
        let before = editor.timeline
        let actionName = enabled ? "De-Breath Audio (Agent)" : "Disable De-Breath (Agent)"
        if !enabled {
            editor.undo.perform(actionName) {
                editor.setDebreath(
                    clipIds: Set(input.clipIds),
                    enabled: false,
                    amount: nil,
                    actionName: actionName
                )
            }
            return mutationResult(
                editor, since: snapshot, touched: before == editor.timeline ? [] : input.clipIds,
                extra: ["noOp": before == editor.timeline],
                notes: ["De-breath disabled."]
            )
        }
        let (jobId, _) = try await editor.startEnhancementJob(
            clipIds: Set(input.clipIds),
            type: .debreath,
            params: .debreath(amount: input.strength),
            actionName: actionName
        )
        let job = try await editor.awaitEnhancementJob(jobId)
        let notes = job.warnings.isEmpty
            ? ["Breath analysis complete."]
            : job.warnings
        return mutationResult(
            editor, since: snapshot, touched: before == editor.timeline ? [] : Array(job.changedClipIds),
            extra: ["noOp": before == editor.timeline, "jobId": jobId.uuidString, "warnings": job.warnings],
            notes: notes
        )
    }

    fileprivate struct EnhanceVoiceInput: DecodableToolArgs {
        let clipIds: [String]
        let amount: Double?
        let deess: Double?
        static let allowedKeys: Set<String> = ["clipIds", "amount", "deess"]
    }

    func enhanceVoice(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: EnhanceVoiceInput = try decodeToolArgs(args, path: "enhance_voice")
        guard !input.clipIds.isEmpty else { throw ToolError("clipIds is empty.") }
        if let amount = input.amount, !(0...1).contains(amount) {
            throw ToolError("amount must be 0–1 (got \(amount))")
        }
        if let deess = input.deess, !(0...1).contains(deess) {
            throw ToolError("deess must be 0–1 (got \(deess))")
        }
        for id in input.clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            guard clip.mediaType == .audio else {
                throw ToolError("Clip \(id) is a \(clip.mediaType.rawValue) clip; enhance_voice needs an audio clip.")
            }
        }

        let snapshot = timelineSnapshot(editor)
        let before = editor.timeline
        let warnings = try await editor.enhanceVoice(
            clipIds: Set(input.clipIds),
            amount: input.amount ?? Clip.defaultEnhanceAmount,
            deess: input.deess ?? Clip.defaultEnhanceDeess,
            actionName: "Enhance Voice (Agent)"
        )
        return mutationResult(
            editor, since: snapshot, touched: before == editor.timeline ? [] : input.clipIds,
            extra: ["noOp": before == editor.timeline, "warnings": warnings],
            notes: warnings
        )
    }

    fileprivate struct MatchLoudnessInput: DecodableToolArgs {
        let clipIds: [String]
        let targetLUFS: Double?
        static let allowedKeys: Set<String> = ["clipIds", "targetLUFS"]
    }

    func matchLoudness(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: MatchLoudnessInput = try decodeToolArgs(args, path: "match_loudness")
        guard !input.clipIds.isEmpty else { throw ToolError("clipIds is empty.") }
        if let target = input.targetLUFS, !(-30...14).contains(target) {
            throw ToolError("targetLUFS must be -30…14 (got \(target))")
        }
        for id in input.clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            guard clip.mediaType == .audio else {
                throw ToolError("Clip \(id) is a \(clip.mediaType.rawValue) clip; match_loudness needs an audio clip.")
            }
        }

        let snapshot = timelineSnapshot(editor)
        let before = editor.timeline
        let warnings = try await editor.matchLoudness(
            clipIds: Set(input.clipIds),
            targetLUFS: input.targetLUFS ?? -16.0,
            actionName: "Match Loudness (Agent)"
        )
        return mutationResult(
            editor, since: snapshot, touched: before == editor.timeline ? [] : input.clipIds,
            extra: ["noOp": before == editor.timeline, "warnings": warnings],
            notes: warnings
        )
    }
}
