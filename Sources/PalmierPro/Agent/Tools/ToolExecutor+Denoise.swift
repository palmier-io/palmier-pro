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
        if let s = input.strength, !(0...100).contains(s) {
            throw ToolError("strength must be 0–100 (got \(s))")
        }
        for id in input.clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            guard clip.mediaType == .audio else {
                throw ToolError("Clip \(id) is a \(clip.mediaType.rawValue) clip; denoise_audio needs an audio clip.")
            }
        }

        let enabled = input.enabled ?? true
        let actionName = enabled ? "Denoise Audio (Agent)" : "Disable Denoise (Agent)"
        withUndoGroup(editor, actionName: actionName) {
            editor.setDenoise(
                clipIds: Set(input.clipIds),
                enabled: enabled,
                amount: input.strength.map { $0 / 100 },
                actionName: actionName
            )
        }
        let count = input.clipIds.count
        let noun = "clip\(count == 1 ? "" : "s")"
        guard enabled else { return .ok("Disabled denoise on \(count) \(noun).") }
        let pct = Int(((input.strength ?? Clip.defaultDenoiseAmount * 100)).rounded())
        return .ok("Denoise enabled at \(pct)% on \(count) \(noun). The bake runs in the background; the preview picks it up automatically when it finishes.")
    }
}
