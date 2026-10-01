import Foundation

extension ToolExecutor {
    private struct FreezeClipInput: DecodableToolArgs {
        let clipId: String?
        let freezeFrames: Int?
        let atFrame: Int?
        let clear: Bool?
        static let allowedKeys: Set<String> = ["clipId", "freezeFrames", "atFrame", "clear"]
    }

    private struct SyncToBeatsInput: DecodableToolArgs {
        let mediaRef: String?
        let clipId: String?
        let beats: [Int]?
        let useDownbeats: Bool?
        let snapFrames: Int?
        static let allowedKeys: Set<String> = [
            "mediaRef", "clipId", "beats", "useDownbeats", "snapFrames",
        ]
    }

    /// Holds a clip's picture on one frame, audio still running, as one undo step.
    func freezeClip(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: FreezeClipInput = try decodeToolArgs(args, path: "freeze_clip")
        guard let clipId = input.clipId, !clipId.isEmpty else {
            throw ToolError("freeze_clip requires clipId.")
        }
        do {
            let receipt: EditorViewModel.FreezeReceipt
            if input.clear == true {
                receipt = try editor.clearFreeze(clipId: clipId)
            } else {
                guard let frames = input.freezeFrames else {
                    throw ToolError("freeze_clip needs freezeFrames, or clear:true.")
                }
                receipt = try editor.freezeFrame(
                    clipId: clipId, atFrame: input.atFrame ?? 0, frames: frames
                )
            }
            return .ok(Self.jsonString([
                "clipId": receipt.clipId,
                "frozenFrame": receipt.frozenFrame,
                "freezeFrames": receipt.freezeFrames,
                "freezeStartFrame": receipt.freezeStartFrame,
                "freezeEndFrame": receipt.freezeEndFrame,
                "resumeFrame": receipt.resumeFrame,
                "audioKeepsPlaying": receipt.audioKeepsPlaying,
                "changed": true,
                "undoSteps": 1,
                "notes": [
                    "The picture holds and the audio runs underneath, so this works over speech.",
                    "Everything after the hold moved later by \(receipt.freezeFrames) frames; "
                        + "one undo step puts it back.",
                ],
            ]) ?? "{}")
        } catch let error as FreezeFrameError {
            throw ToolError(error.description)
        }
    }

    /// Cuts a clip on the music's beats, in one undo step.
    func syncToBeats(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: SyncToBeatsInput = try decodeToolArgs(args, path: "sync_to_beats")
        guard let mediaRef = input.mediaRef, !mediaRef.isEmpty else {
            throw ToolError("sync_to_beats requires mediaRef — the music asset detect_beats read.")
        }
        guard let clipId = input.clipId, !clipId.isEmpty else {
            throw ToolError("sync_to_beats requires clipId — the clip to cut.")
        }
        do {
            let receipt = try await editor.syncClipToBeats(
                clipId: clipId, musicRef: mediaRef,
                requestedIndices: input.beats,
                useDownbeats: input.useDownbeats ?? false,
                snapFrames: input.snapFrames ?? 2
            )
            let moved = receipt.cuts.filter { $0.snappedBy != 0 }.count
            return .ok(Self.jsonString([
                "clipId": receipt.clipId,
                "usedDownbeats": receipt.usedDownbeats,
                "reusedCachedBeats": receipt.reusedCachedBeats,
                "cutCount": receipt.cuts.count,
                "cuts": receipt.cuts.map { cut -> [String: Any] in
                    [
                        "beatIndex": cut.index,
                        "beatSeconds": cut.beatSeconds,
                        "exactFrame": cut.exactFrame,
                        "frame": cut.frame,
                        "snappedBy": cut.snappedBy,
                    ]
                },
                "changed": true,
                "undoSteps": 1,
                "notes": [
                    "Every cut frame is reported so an effect can sit exactly on it.",
                    moved > 0
                        ? "\(moved) cut(s) moved by the snap. Raise snapFrames, or pass 0 to use the beats exactly."
                        : "Every cut landed exactly on its beat.",
                    "The clip is now \(receipt.cuts.count + 1) pieces; one undo step rejoins them.",
                ],
            ]) ?? "{}")
        } catch let error as BeatSyncError {
            throw ToolError(error.description)
        }
    }
}
