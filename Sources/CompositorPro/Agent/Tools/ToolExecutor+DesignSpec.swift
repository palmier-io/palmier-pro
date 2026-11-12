import Foundation

extension ToolExecutor {

    /// Parses and applies a video design specification (`frame.md` or `design.md`) to the project.
    func applyDesignSpec(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try Task.checkCancellation()
        try validateUnknownKeys(
            args,
            allowed: ["specMarkdown", "filePath", "updateTimeline", "restyleClips", "applyGrade", "savePreferences"],
            path: "apply_design_spec"
        )

        let markdown: String
        if let raw = args.string("specMarkdown"), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            markdown = raw
        } else if let path = args.string("filePath"), !path.isEmpty {
            markdown = try await Task.detached {
                guard FileManager.default.fileExists(atPath: path) else {
                    throw ToolError("Design spec file not found at path: \(path)")
                }
                return try String(contentsOfFile: path, encoding: .utf8)
            }.value
        } else {
            throw ToolError("apply_design_spec requires either 'specMarkdown' or 'filePath'.")
        }

        let spec = try DesignSpecParser.parse(markdown: markdown)
        let updateTimeline = args.bool("updateTimeline") ?? true
        let restyleClips = args.bool("restyleClips") ?? true
        let applyGrade = args.bool("applyGrade") ?? true
        let savePreferences = args.bool("savePreferences") ?? true

        let receipt = try editor.applyDesignSpec(
            spec,
            updateTimelineGeometry: updateTimeline,
            restyleClips: restyleClips,
            applyGrade: applyGrade,
            updatePreferences: savePreferences
        )

        var payload: [String: Any] = [
            "status": "ok",
            "retypedClipsCount": receipt.retypedClipsCount,
            "updatedClipIds": receipt.updatedClipIds,
            "gradedClipsCount": receipt.gradedClipsCount,
            "updatedPreferences": receipt.updatedPreferences,
        ]
        if let ar = receipt.appliedAspectRatio { payload["appliedAspectRatio"] = ar }
        if let dims = receipt.newDimensions { payload["newDimensions"] = dims }
        if let preset = receipt.appliedGradePreset { payload["appliedGradePreset"] = preset }
        if let cap = receipt.appliedCaptionTemplate { payload["appliedCaptionTemplate"] = cap }

        return .ok(Self.jsonString(payload) ?? "{}")
    }

    /// Exports the active project's canvas geometry, typography, palette, and style preferences to `frame.md`.
    func exportDesignSpec(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try Task.checkCancellation()
        try validateUnknownKeys(args, allowed: ["filePath"], path: "export_design_spec")

        let spec = editor.exportCurrentDesignSpec()
        let markdown = DesignSpecParser.exportMarkdown(spec: spec)

        if let path = args.string("filePath"), !path.isEmpty {
            try await Task.detached {
                try markdown.write(toFile: path, atomically: true, encoding: .utf8)
            }.value
        }

        var payload: [String: Any] = [
            "status": "ok",
            "markdown": markdown,
            "aspectRatio": spec.canvas.aspectRatio ?? "\(editor.timeline.width):\(editor.timeline.height)",
            "width": spec.canvas.width ?? editor.timeline.width,
            "height": spec.canvas.height ?? editor.timeline.height,
        ]
        if let disp = spec.typography.displayFont { payload["displayFont"] = disp }
        if let body = spec.typography.bodyFont { payload["bodyFont"] = body }
        if let p = spec.grade.preset { payload["gradePreset"] = p }
        if let t = spec.caption.templateId { payload["captionTemplate"] = t }

        return .ok(Self.jsonString(payload) ?? "{}")
    }
}

