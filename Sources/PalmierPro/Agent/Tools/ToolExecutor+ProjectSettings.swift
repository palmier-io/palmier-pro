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

    func setProjectSettings(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
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

        var changes: [String] = []
        if newFPS != prevFPS { changes.append("fps \(prevFPS) → \(newFPS)") }
        if newWidth != prevWidth || newHeight != prevHeight {
            changes.append("resolution \(prevWidth)×\(prevHeight) → \(newWidth)×\(newHeight)")
        }

        if changes.isEmpty {
            return .ok("No change — settings already match: \(newWidth)×\(newHeight) @ \(newFPS)fps")
        }
        return .ok("Updated: \(changes.joined(separator: ", ")). Now \(newWidth)×\(newHeight) @ \(newFPS)fps.")
    }

    /// Mirrors the UI's first-clip settings check: auto-applies timeline settings to match
    /// the first video asset when the timeline is empty or unconfigured.
    /// Returns a note string if settings changed, nil otherwise.
    func applySettingsIfNeededForAgent(_ editor: EditorViewModel, assets: [MediaAsset]) -> String? {
        let prevFPS = editor.timeline.fps
        let prevWidth = editor.timeline.width
        let prevHeight = editor.timeline.height

        switch editor.checkProjectSettings(for: assets) {
        case .proceed:
            // checkProjectSettings silently auto-applied on the first-ever clip when !settingsConfigured
            guard editor.timeline.fps != prevFPS
                    || editor.timeline.width != prevWidth
                    || editor.timeline.height != prevHeight else { return nil }
            return "Set timeline to \(editor.timeline.width)×\(editor.timeline.height) @ \(editor.timeline.fps)fps to match clip."
        case .mismatch(let fps, let width, let height):
            editor.applyTimelineSettings(fps: fps, width: width, height: height)
            return "Matched timeline to clip: \(width)×\(height) @ \(fps)fps."
        }
    }
}
