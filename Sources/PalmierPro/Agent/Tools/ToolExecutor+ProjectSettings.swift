import Foundation

fileprivate struct SetProjectSettingsInput: DecodableToolArgs {
    let fps: Int?
    let width: Int?
    let height: Int?
    let aspectRatio: String?
    let quality: String?
    static let allowedKeys: Set<String> = ["fps", "width", "height", "aspectRatio", "quality"]
}

extension ToolExecutor {

    struct ValidatedProjectSettings {
        fileprivate let input: SetProjectSettingsInput
        let aspectPreset: AspectPreset?
        let qualityPreset: QualityPreset?
    }

    @discardableResult
    func validateProjectSettings(_ args: [String: Any]) throws -> ValidatedProjectSettings {
        let input: SetProjectSettingsInput = try decodeToolArgs(args, path: "set_project_settings")

        guard input.fps != nil || input.width != nil || input.height != nil
                || input.aspectRatio != nil || input.quality != nil else {
            throw ToolError("Provide at least one of: fps, width, height, aspectRatio, quality")
        }
        if input.aspectRatio != nil && (input.width != nil || input.height != nil) {
            throw ToolError("'aspectRatio' and explicit 'width'/'height' are mutually exclusive")
        }
        if let fps = input.fps, fps < 1 || fps > 120 {
            throw ToolError("fps must be between 1 and 120 (got \(fps))")
        }

        let aspectPreset: AspectPreset? = try input.aspectRatio.map { ar in
            switch ar {
            case "16:9":   return .sixteenNine
            case "9:16":   return .nineSixteen
            case "1:1":    return .oneOne
            case "4:3":    return .fourThree
            case "2.4:1":  return .twoPointFourOne
            case "9:14":   return .nineByFourteen
            default:
                throw ToolError("Unknown aspectRatio '\(ar)'. Use one of: 16:9, 9:16, 1:1, 4:3, 2.4:1, 9:14")
            }
        }

        let qualityPreset: QualityPreset? = try input.quality.map { q in
            switch q {
            case "720p":  return .hd720
            case "1080p": return .fullHD
            case "2K":    return .twoK
            case "4K":    return .fourK
            default:
                throw ToolError("Unknown quality '\(q)'. Use one of: 720p, 1080p, 2K, 4K")
            }
        }
        return ValidatedProjectSettings(input: input, aspectPreset: aspectPreset, qualityPreset: qualityPreset)
    }

    func setProjectSettings(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let settings = try validateProjectSettings(args)
        let input = settings.input
        let aspectPreset = settings.aspectPreset
        let qualityPreset = settings.qualityPreset

        let newFPS = input.fps ?? editor.timeline.fps
        let newWidth: Int
        let newHeight: Int

        if let preset = aspectPreset {
            var baseW = preset.width
            var baseH = preset.height
            if let quality = qualityPreset {
                let scaled = quality.resolution(currentWidth: baseW, currentHeight: baseH)
                baseW = scaled.width
                baseH = scaled.height
            }
            newWidth = baseW
            newHeight = baseH
        } else if let quality = qualityPreset {
            let scaled = quality.resolution(currentWidth: editor.timeline.width, currentHeight: editor.timeline.height)
            newWidth = scaled.width
            newHeight = scaled.height
        } else {
            newWidth = input.width ?? editor.timeline.width
            newHeight = input.height ?? editor.timeline.height
        }

        guard newWidth > 0 && newHeight > 0 else {
            throw ToolError("Resolution must have positive width and height")
        }

        let prevFPS = editor.timeline.fps
        let prevWidth = editor.timeline.width
        let prevHeight = editor.timeline.height

        editor.applyTimelineSettings(fps: newFPS, width: newWidth, height: newHeight)
        editor.undoManager?.setActionName("Set Project Settings (Agent)")

        var changed: [String] = []
        if newFPS != prevFPS { changed.append("fps") }
        if newWidth != prevWidth || newHeight != prevHeight { changed.append("resolution") }

        var payload: [String: Any] = [
            "fps": newFPS,
            "resolution": "\(newWidth)x\(newHeight)",
            "changed": changed,
        ]
        if changed.isEmpty {
            payload["note"] = "Settings already matched."
        } else if changed.contains("fps") {
            payload["note"] = "Clip frames rescaled to \(newFPS)fps — re-read get_timeline before frame-based edits."
        }
        return .ok(Self.jsonString(payload) ?? "{}")
    }

    /// Syncs timeline resolution with the first clip if needed; returns a note if changed, nil otherwise.
    func applySettingsIfNeededForAgent(_ editor: EditorViewModel, assets: [MediaAsset]) -> String? {
        let prevWidth = editor.timeline.width
        let prevHeight = editor.timeline.height

        // adoptFPS: false — only resolution syncs, fps stays unchanged.
        var notes: [String] = []
        switch editor.checkProjectSettings(for: assets, adoptFPS: false) {
        case .proceed:
            if editor.timeline.width != prevWidth || editor.timeline.height != prevHeight {
                notes.append("Set timeline to \(editor.timeline.width)×\(editor.timeline.height) to match clip.")
            }
        case .mismatch(_, let width, let height):
            editor.applyTimelineSettings(fps: editor.timeline.fps, width: width, height: height)
            notes.append("Matched timeline resolution to clip: \(width)×\(height).")
        }

        if let clipFPS = assets.first(where: { $0.type == .video })?.sourceFPS.flatMap({ Int($0.rounded()) }),
           clipFPS != editor.timeline.fps {
            notes.append("Clip is \(clipFPS)fps but project is \(editor.timeline.fps)fps; clips placed at \(editor.timeline.fps)fps and frame counts are interpreted at \(editor.timeline.fps)fps. To conform, call set_project_settings then re-read get_timeline.")
        }

        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}
