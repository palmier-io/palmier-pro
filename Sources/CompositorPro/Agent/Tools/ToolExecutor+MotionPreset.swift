import Foundation

extension ToolExecutor {
    private struct ApplyMotionPresetInput: DecodableToolArgs {
        let preset: String?
        let clipIds: [String]
        let durationFrames: Int?
        let overwrite: Bool?
        static let allowedKeys: Set<String> = ["preset", "clipIds", "durationFrames", "overwrite"]
    }

    func applyMotionPreset(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: ApplyMotionPresetInput = try decodeToolArgs(args, path: "apply_motion_preset")
        guard let rawPreset = input.preset, let preset = MotionPreset(rawValue: rawPreset) else {
            throw ToolError("preset must be one of: \(MotionPreset.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard !input.clipIds.isEmpty else { throw ToolError("clipIds must not be empty.") }
        if let duration = input.durationFrames, duration < 2 {
            throw ToolError("durationFrames must be at least 2.")
        }

        let overwrite = input.overwrite ?? false
        var replacements: [String: Clip] = [:]
        for id in input.clipIds {
            guard var clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            guard clip.mediaType.isVisual else {
                throw ToolError("Clip \(id) is not visual and cannot use a motion preset.")
            }
            let occupied = occupiedProperties(for: preset, clip: clip)
            if !overwrite, !occupied.isEmpty {
                throw ToolError("Clip \(id) already has \(occupied.joined(separator: ", ")) keyframes. Pass overwrite=true to replace them.")
            }
            clip.applyMotionPreset(preset, requestedDuration: input.durationFrames)
            replacements[id] = clip
        }

        let changed = input.clipIds.filter { id in
            guard let current = editor.clipFor(id: id), let replacement = replacements[id] else { return false }
            return current != replacement
        }
        guard !changed.isEmpty else {
            return .ok(Self.jsonString([
                "preset": preset.rawValue, "changed": false, "noOp": true, "clipIds": input.clipIds,
            ]) ?? "{}")
        }

        let actionName = changed.count == 1 ? "Motion: \(preset.rawValue)" : "Motion: \(preset.rawValue) ×\(changed.count)"
        editor.undo.perform(actionName) {
            editor.mutateClips(ids: Set(changed), actionName: actionName) { clip in
                guard let replacement = replacements[clip.id] else { return }
                clip.opacityTrack = replacement.opacityTrack
                clip.positionTrack = replacement.positionTrack
                clip.scaleTrack = replacement.scaleTrack
            }
        }
        editor.notifyTimelineChanged()
        return .ok(Self.jsonString([
            "preset": preset.rawValue,
            "changed": true,
            "noOp": false,
            "clipIds": changed,
            "undoSteps": 1,
        ]) ?? "{}")
    }

    private func occupiedProperties(for preset: MotionPreset, clip: Clip) -> [String] {
        switch preset {
        case .fadeIn:
            clip.opacityTrack?.isActive == true ? ["opacity"] : []
        case .slideUp:
            [clip.opacityTrack?.isActive == true ? "opacity" : nil,
             clip.positionTrack?.isActive == true ? "position" : nil].compactMap { $0 }
        case .punchIn:
            [clip.opacityTrack?.isActive == true ? "opacity" : nil,
             clip.scaleTrack?.isActive == true ? "scale" : nil].compactMap { $0 }
        case .gentlePush:
            clip.scaleTrack?.isActive == true ? ["scale"] : []
        }
    }
}
