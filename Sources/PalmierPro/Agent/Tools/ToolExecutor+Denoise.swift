import Foundation

extension ToolExecutor {
    fileprivate struct DenoiseAudioInput: DecodableToolArgs {
        let clipIds: [String]
        let strength: Double?
        let enabled: Bool?
        static let allowedKeys: Set<String> = ["clipIds", "strength", "enabled"]
    }

    func denoiseAudio(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: DenoiseAudioInput = try decodeToolArgs(args, path: "denoise_audio")
        guard !input.clipIds.isEmpty else { throw ToolError("clipIds is empty.") }
        if let s = input.strength, !(0...1).contains(s) {
            throw ToolError("strength must be 0–1 (got \(s))")
        }
        for id in input.clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            guard clip.mediaType == .audio else {
                throw ToolError("Clip \(id) is a \(clip.mediaType.rawValue) clip; denoise_audio needs an audio clip.")
            }
        }

        let enabled = input.enabled ?? true
        let snapshot = timelineSnapshot(editor)
        let actionName = enabled ? "Denoise Audio (Agent)" : "Disable Denoise (Agent)"
        try withUndoGroup(editor, actionName: actionName) {
            editor.setDenoise(
                clipIds: Set(input.clipIds),
                enabled: enabled,
                amount: input.strength,
                actionName: actionName
            )
        }
        let notes = enabled
            ? ["Denoise bakes in the background; the preview picks it up automatically when it finishes."]
            : []
        return mutationResult(editor, since: snapshot, touched: input.clipIds, notes: notes)
    }
}
