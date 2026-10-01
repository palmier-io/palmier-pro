import Foundation

extension ToolExecutor {
    private struct ApplyStylePresetInput: DecodableToolArgs {
        let preset: String?
        let clipIds: [String]?
        static let allowedKeys: Set<String> = ["preset", "clipIds"]
    }

    /// Writes a named look to visual clips, through the same domain path as `apply_color`.
    func applyStylePreset(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: ApplyStylePresetInput = try decodeToolArgs(args, path: "apply_style_preset")
        guard let rawId = input.preset, !rawId.isEmpty else {
            throw ToolError("apply_style_preset requires preset. One of: \(StylePresets.ids.joined(separator: ", ")).")
        }
        guard let preset = StylePresets.preset(id: rawId) else {
            throw ToolError("Unknown preset '\(rawId)'. One of: \(StylePresets.ids.joined(separator: ", ")).")
        }
        try validateUnknownKeys(
            preset.color, allowed: Self.colorObjectAllowedKeys, path: "apply_style_preset.preset"
        )
        let clipIds = try styleTargets(editor, explicit: input.clipIds)
        guard !clipIds.isEmpty else {
            throw ToolError("No video or image clips to grade. Add media with add_clips first.")
        }
        // Refuse before mutating, so a bad target never leaves a half-graded timeline.
        for id in clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            guard clip.mediaType == .video || clip.mediaType == .image else {
                throw ToolError("Clip \(id) is a \(clip.mediaType.rawValue) clip; a look needs a video or image clip.")
            }
        }

        let stack = GradeState(colorDict: preset.color).buildStack()
        let snapshot = timelineSnapshot(editor)
        let actionName = clipIds.count == 1 ? "Style: \(preset.id)" : "Style: \(preset.id) ×\(clipIds.count)"
        editor.undo.perform(actionName) {
            editor.mutateClips(ids: Set(clipIds), actionName: actionName) { clip in
                writeCompleteGrade(&clip, stack: stack)
            }
        }
        var payload: [String: Any] = [
            "preset": preset.id,
            "graded": clipIds.count,
            "skipped": 0,
            "changed": true,
            "undoSteps": 1,
            "notes": [
                "\(clipIds.count) clip(s) now share the \(preset.id) look; one undo step reverts all of them.",
                "A look is color only — music, transitions and pacing stay separate decisions.",
                "Replaces each clip's existing grade. Use apply_color to nudge from there.",
            ],
        ]
        for id in clipIds {
            guard let clip = editor.clipFor(id: id), let color = Self.colorObject(from: clip.effects) else { continue }
            payload[id] = color
        }
        return .ok(Self.jsonString(payload) ?? "{}")
    }

    /// Replaces a clip's grade, leaving every non-color effect alone. Shared with `apply_color`'s
    /// paste path so a pasted grade and a preset grade are the same operation.
    func writeCompleteGrade(_ clip: inout Clip, stack: [Effect]) {
        clip.effects = (clip.effects ?? []).filter { !$0.type.hasPrefix("color.") } + stack
    }

    /// Defaults to every visual clip, which is what "give this cut a look" means.
    private func styleTargets(_ editor: EditorViewModel, explicit: [String]?) throws -> [String] {
        if let explicit, !explicit.isEmpty { return explicit }
        return editor.timeline.tracks
            .flatMap(\.clips)
            .filter { $0.mediaType == .video || $0.mediaType == .image }
            .map(\.id)
    }
}
