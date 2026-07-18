import Foundation

extension ToolExecutor {
    fileprivate struct ApplyTransitionInput: DecodableToolArgs {
        struct Entry: Decodable {
            let outgoingClipId: String
            let incomingClipId: String
            let type: String
            let durationFrames: Int?
        }
        let transitions: [Entry]?
        let incomingClipIds: [String]?
        static let allowedKeys: Set<String> = ["transitions", "incomingClipIds"]
    }

    /// Apply or remove clip-to-clip transitions at edit points.
    func applyTransition(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: ApplyTransitionInput = try decodeToolArgs(args, path: "apply_transition")
        let adds = input.transitions ?? []
        let removes = input.incomingClipIds ?? []
        guard !adds.isEmpty || !removes.isEmpty else {
            throw ToolError("Provide transitions to apply or incomingClipIds to remove.")
        }

        for entry in adds {
            guard TransitionRegistry.contains(entry.type) else {
                throw ToolError(
                    "Unknown transition '\(entry.type)'. See the apply_transition description for available types."
                )
            }
            if let d = entry.durationFrames {
                guard d >= 1, d <= 10_000 else {
                    throw ToolError("durationFrames must be between 1 and 10000.")
                }
            }
            try validateTransitionPair(
                editor,
                outgoingId: entry.outgoingClipId,
                incomingId: entry.incomingClipId,
                duration: entry.durationFrames
            )
        }
        for id in removes {
            guard editor.clipFor(id: id) != nil else { throw ToolError("Clip not found: \(id)") }
        }

        let snapshot = timelineSnapshot(editor)
        var touched = Set<String>()
        let actionName: String = {
            if adds.count == 1 && removes.isEmpty { return "Apply Transition (Agent)" }
            if adds.isEmpty && removes.count == 1 { return "Remove Transition (Agent)" }
            return "Apply Transitions (Agent)"
        }()

        try editor.undo.perform(actionName) {
            for id in removes {
                try editor.removeTransition(incomingId: id)
                touched.insert(id)
            }
            for entry in adds {
                try editor.applyTransition(
                    outgoingId: entry.outgoingClipId,
                    incomingId: entry.incomingClipId,
                    type: entry.type,
                    durationFrames: entry.durationFrames
                )
                touched.insert(entry.outgoingClipId)
                touched.insert(entry.incomingClipId)
            }
        }

        var extra: [String: Any] = [:]
        if !adds.isEmpty {
            extra["applied"] = adds.map { entry -> [String: Any] in
                var row: [String: Any] = [
                    "outgoingClipId": entry.outgoingClipId,
                    "incomingClipId": entry.incomingClipId,
                    "type": entry.type,
                ]
                if let inn = editor.clipFor(id: entry.incomingClipId), let t = inn.transition {
                    row["durationFrames"] = t.durationFrames
                }
                return row
            }
        }
        if !removes.isEmpty {
            extra["removed"] = removes
        }
        return mutationResult(editor, since: snapshot, touched: Array(touched), extra: extra)
    }

    private func validateTransitionPair(
        _ editor: EditorViewModel,
        outgoingId: String,
        incomingId: String,
        duration: Int?
    ) throws {
        guard let outLoc = editor.findClip(id: outgoingId) else {
            throw ToolError("Clip not found: \(outgoingId)")
        }
        guard let inLoc = editor.findClip(id: incomingId) else {
            throw ToolError("Clip not found: \(incomingId)")
        }
        guard outLoc.trackIndex == inLoc.trackIndex else {
            throw ToolError("Clips must be on the same track.")
        }
        let outgoing = editor.timeline.tracks[outLoc.trackIndex].clips[outLoc.clipIndex]
        let incoming = editor.timeline.tracks[inLoc.trackIndex].clips[inLoc.clipIndex]
        guard outgoing.supportsTransition else {
            throw ToolError("Clip \(outgoingId) cannot take a transition.")
        }
        guard incoming.supportsTransition else {
            throw ToolError("Clip \(incomingId) cannot take a transition.")
        }
        let d = duration ?? editor.defaultTransitionDurationFrames()
        let maxDuration = min(outgoing.durationFrames, incoming.durationFrames) - 1
        guard d >= 1, maxDuration >= 1, d <= maxDuration else {
            throw ToolError("durationFrames \(d) is out of range (1…\(max(1, maxDuration))).")
        }
        let abutting = incoming.startFrame == outgoing.endFrame
        let validExisting = Clip.hasValidTransition(outgoing: outgoing, incoming: incoming)
        let overlapped = Clip.overlapFrames(outgoing: outgoing, incoming: incoming) > 0
            && incoming.transition != nil
        guard abutting || validExisting || overlapped else {
            throw ToolError(
                "Clips must be adjacent on the same track (outgoing end must meet incoming start)."
            )
        }
    }
}
