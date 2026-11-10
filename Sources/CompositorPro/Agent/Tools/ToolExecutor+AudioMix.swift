import Foundation

extension ToolExecutor {
    private struct CrossfadeAudioInput: DecodableToolArgs {
        let outgoingClipId: String?
        let incomingClipId: String?
        let durationFrames: Int?
        let curve: String?
        static let allowedKeys: Set<String> = [
            "outgoingClipId", "incomingClipId", "durationFrames", "curve",
        ]
    }

    private struct DuckAudioInput: DecodableToolArgs {
        let bedClipId: String?
        let sourceClipIds: [String]?
        let duckDb: Double?
        let attackFrames: Int?
        let holdFrames: Int?
        let releaseFrames: Int?
        let mergeGapFrames: Int?
        let overwrite: Bool?
        let allowWholeClipFallback: Bool?
        static let allowedKeys: Set<String> = [
            "bedClipId", "sourceClipIds", "duckDb", "attackFrames", "holdFrames",
            "releaseFrames", "mergeGapFrames", "overwrite", "allowWholeClipFallback",
        ]
    }

    /// Crossfades two adjacent audio clips on one track, as one undo step.
    func crossfadeAudio(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: CrossfadeAudioInput = try decodeToolArgs(args, path: "crossfade_audio")
        guard let outgoingId = input.outgoingClipId, !outgoingId.isEmpty else {
            throw ToolError("crossfade_audio requires outgoingClipId.")
        }
        guard let incomingId = input.incomingClipId, !incomingId.isEmpty else {
            throw ToolError("crossfade_audio requires incomingClipId.")
        }
        let duration = input.durationFrames ?? 12
        do {
            let receipt = try editor.crossfadeAudio(
                outgoingId: outgoingId, incomingId: incomingId,
                durationFrames: duration, curve: input.curve ?? "smooth"
            )
            return .ok(Self.jsonString([
                "outgoingClipId": receipt.outgoingClipId,
                "incomingClipId": receipt.incomingClipId,
                "cutFrame": receipt.cutFrame,
                "durationFrames": receipt.durationFrames,
                "curve": receipt.curve,
                "equalPowerSamples": receipt.equalPowerSamples,
                "changed": true,
                "notes": [
                    "One undo step restores both clips to their previous fades and keyframes.",
                    receipt.curve == "equalPower"
                        ? "Equal power holds perceived loudness through the overlap; a linear fade dips about 3 dB at the cut."
                        : "Set curve to equalPower to hold perceived loudness through the overlap.",
                ],
            ]) ?? "{}")
        } catch let error as AudioMixError {
            throw ToolError(error.description)
        } catch let error as DuckingPlan.Failure {
            throw ToolError(error.description)
        }
    }

    /// Lowers a bed clip under whatever dialogue is playing, as one undo step.
    func duckAudio(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: DuckAudioInput = try decodeToolArgs(args, path: "duck_audio")
        guard let bedId = input.bedClipId, !bedId.isEmpty else {
            throw ToolError("duck_audio requires bedClipId.")
        }
        let defaults = DuckingPlan.Parameters.default
        do {
            let receipt = try await editor.duckAudio(
                bedId: bedId,
                sourceIds: input.sourceClipIds,
                duckDb: input.duckDb ?? defaults.duckDb,
                attackFrames: input.attackFrames ?? defaults.attackFrames,
                holdFrames: input.holdFrames ?? defaults.holdFrames,
                releaseFrames: input.releaseFrames ?? defaults.releaseFrames,
                mergeGapFrames: input.mergeGapFrames ?? defaults.mergeGapFrames,
                overwrite: input.overwrite ?? false,
                allowWholeClipFallback: input.allowWholeClipFallback ?? true
            )
            var payload: [String: Any] = [
                "bedClipId": receipt.bedClipId,
                "sourceClipIds": receipt.sourceClipIds,
                "duckDb": receipt.duckDb,
                "duckedRanges": receipt.duckedRanges.map { ["startFrame": $0.lowerBound, "endFrame": $0.upperBound] },
                "keyframesWritten": receipt.keyframesWritten,
                "ignoredSpans": receipt.ignoredSpans,
                "changed": receipt.changed,
                "noOp": !receipt.changed,
                "speechDetectionByClip": receipt.speechDetection,
            ]
            var notes = ["One undo step removes the whole envelope, not one keyframe at a time."]
            if receipt.usedWholeClipFallback {
                payload["speechDetection"] = "unavailable"
                notes.append(
                    "Speech could not be detected for at least one source, so that clip's full range "
                        + "was treated as speech and the bed is held down across all of it. Reported as "
                        + "speechDetection:unavailable rather than silently approximated."
                )
            } else {
                payload["speechDetection"] = "measured_timing"
            }
            if !receipt.sourceClipIds.isEmpty, input.sourceClipIds == nil {
                notes.append("Sources defaulted to every overlapping audio clip other than the bed.")
            }
            payload["notes"] = notes
            return .ok(Self.jsonString(payload) ?? "{}")
        } catch let error as AudioMixError {
            throw ToolError(error.description)
        } catch let error as DuckingPlan.Failure {
            throw ToolError(error.description)
        }
    }
}
