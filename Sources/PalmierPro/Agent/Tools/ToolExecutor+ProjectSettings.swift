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
        let aspectRatio: CanvasAspectRatio?
        let quality: QualityPreset?

        func resolve(for timeline: Timeline) throws -> (fps: Int, width: Int, height: Int) {
            var size = (input.width ?? timeline.width, input.height ?? timeline.height)
            if let aspectRatio {
                do {
                    size = try aspectRatio.resolution(shortEdge: quality?.shortEdge ?? min(timeline.width, timeline.height))
                } catch {
                    throw ToolError(error.localizedDescription)
                }
            } else if let quality, size.0 > 0, size.1 > 0 {
                size = quality.resolution(currentWidth: size.0, currentHeight: size.1)
            }
            let changesResolution = input.width != nil || aspectRatio != nil || quality != nil
            guard size.0 > 0, size.1 > 0,
                  !changesResolution || (size.0 <= 8_192 && size.1 <= 8_192) else {
                throw ToolError("Resolution must be positive and no larger than 8192 pixels on either edge")
            }
            return (input.fps ?? timeline.fps, size.0, size.1)
        }
    }

    @discardableResult
    func validateProjectSettings(_ args: [String: Any]) throws -> ValidatedProjectSettings {
        let input: SetProjectSettingsInput = try decodeToolArgs(args, path: "set_project_settings")

        guard input.fps != nil || input.width != nil || input.height != nil
                || input.aspectRatio != nil || input.quality != nil else {
            throw ToolError("Provide at least one of: fps, width, height, aspectRatio, quality")
        }
        guard (input.width == nil) == (input.height == nil) else {
            throw ToolError("Provide both width and height")
        }
        if input.width != nil, input.aspectRatio != nil || input.quality != nil {
            throw ToolError("Explicit dimensions can't be combined with aspectRatio or quality")
        }
        if let fps = input.fps, !(1...120).contains(fps) {
            throw ToolError("fps must be between 1 and 120 (got \(fps))")
        }
        let aspectRatio: CanvasAspectRatio? = try input.aspectRatio.map {
            do { return try CanvasAspectRatio($0) }
            catch { throw ToolError(error.localizedDescription) }
        }
        let quality: QualityPreset? = try input.quality.map {
            switch $0 {
            case "720p":  return .hd720
            case "1080p": return .fullHD
            case "2K":    return .twoK
            case "4K":    return .fourK
            default:
                throw ToolError("Unknown quality '\($0)'. Use one of: 720p, 1080p, 2K, 4K")
            }
        }
        return ValidatedProjectSettings(input: input, aspectRatio: aspectRatio, quality: quality)
    }

    func setProjectSettings(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let settings = try validateProjectSettings(args).resolve(for: editor.timeline)
        return editor.undo.perform("Set Project Settings (Agent)") {
            setProjectSettings(editor, settings)
        }
    }

    func setProjectSettings(
        _ editor: EditorViewModel,
        _ resolved: (fps: Int, width: Int, height: Int)
    ) -> ToolResult {
        let newFPS = resolved.fps
        let newWidth = resolved.width
        let newHeight = resolved.height

        let prevFPS = editor.timeline.fps
        let prevWidth = editor.timeline.width
        let prevHeight = editor.timeline.height

        editor.applyTimelineSettings(fps: newFPS, width: newWidth, height: newHeight)

        var changed: [String] = []
        if newFPS != prevFPS { changed.append("fps") }
        if newWidth != prevWidth || newHeight != prevHeight { changed.append("resolution") }

        var payload: [String: Any] = [
            "fps": newFPS,
            "resolution": "\(newWidth)x\(newHeight)",
            "aspectRatio": CanvasAspectRatio.displayLabel(width: newWidth, height: newHeight),
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
