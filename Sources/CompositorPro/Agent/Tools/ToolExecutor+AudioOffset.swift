import Foundation

extension ToolExecutor {
    private struct OffsetAudioInput: DecodableToolArgs {
        let videoClipId: String?
        let offsetFrames: Int?
        let clear: Bool?
        static let allowedKeys: Set<String> = ["videoClipId", "offsetFrames", "clear"]
    }

    /// Offsets a linked video/audio pair across their cut — a J-cut or an L-cut — in one step.
    func offsetAudio(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: OffsetAudioInput = try decodeToolArgs(args, path: "offset_audio")
        guard let videoId = input.videoClipId, !videoId.isEmpty else {
            throw ToolError("offset_audio requires videoClipId — the video clip of the linked pair.")
        }
        guard editor.clipFor(id: videoId) != nil else {
            throw ToolError("Clip not found: \(videoId)")
        }
        do {
            let receipt: EditorViewModel.AudioOffsetReceipt
            if input.clear == true {
                receipt = try editor.clearAudioOffset(videoId: videoId)
            } else {
                guard let offset = input.offsetFrames else {
                    throw ToolError("offset_audio needs offsetFrames (positive = J-cut, negative = L-cut), or clear:true.")
                }
                guard let audioId = linkedAudioId(of: videoId, editor: editor) else {
                    throw ToolError("Clip \(videoId) has no linked audio partner. "
                        + "add_clips creates one automatically for media that has audio; "
                        + "for a separately placed audio clip, link them with manage_clip_links first.")
                }
                receipt = try editor.offsetLinkedAudio(
                    videoId: videoId, audioId: audioId, offsetFrames: offset
                )
            }
            return .ok(Self.jsonString([
                "videoClipId": receipt.videoClipId,
                "audioClipId": receipt.audioClipId,
                "cutFrame": receipt.cutFrame,
                "offsetFrames": receipt.offsetFrames,
                "kind": receipt.kind,
                "audioStartFrame": receipt.audioStartFrame,
                "audioEndFrame": receipt.audioEndFrame,
                "changed": true,
                "undoSteps": 1,
                "notes": [
                    receipt.kind == "jCut"
                        ? "J-cut: the audio now starts before the picture changes."
                        : (receipt.kind == "lCut"
                            ? "L-cut: the audio now runs past the picture change."
                            : "Picture and sound are locked again."),
                    "The link stays intact, so the pair still travels together. "
                        + "clear:true puts it back.",
                ],
            ]) ?? "{}")
        } catch let error as AudioOffsetError {
            throw ToolError(error.description)
        }
    }

    /// The audio partner of a linked video clip, so callers only name the video.
    private func linkedAudioId(of videoId: String, editor: EditorViewModel) -> String? {
        for id in editor.linkedPartnerIds(of: videoId) {
            if let location = editor.findClip(id: id),
               editor.timeline.tracks[location.trackIndex].clips[location.clipIndex].mediaType == .audio {
                return id
            }
        }
        return nil
    }
}
