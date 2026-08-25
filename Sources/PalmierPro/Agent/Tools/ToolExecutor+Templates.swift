import Foundation

extension ToolExecutor {
    private static let createTemplateFromReelAllowedKeys: Set<String> = ["mediaRef", "mode"]
    private static let fillTemplateSlotAllowedKeys: Set<String> = ["clipId", "mediaRef"]

    func createTemplateFromReel(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.createTemplateFromReelAllowedKeys, path: "create_template_from_reel")
        let mediaRef = try args.requireString("mediaRef")
        let asset = try asset(mediaRef, editor: editor)
        guard asset.type == .video else {
            throw ToolError("create_template_from_reel needs a video: \(mediaRef) is \(asset.type.rawValue).")
        }
        guard FileManager.default.fileExists(atPath: asset.url.path) else {
            throw ToolError("Media file not on disk: \(asset.url.lastPathComponent)")
        }
        let mode = try Self.templateMode(args)

        let receipt: TemplateGenerationReceipt
        do {
            receipt = try await editor.createTemplateFromReel(assetId: mediaRef, mode: mode)
        } catch EditorViewModel.TemplateStudioError.generationInProgress {
            throw ToolError("A reel analysis is already running. Wait for it to finish, then retry.")
        } catch EditorViewModel.TemplateStudioError.assetNotFound {
            throw ToolError("Asset \(mediaRef) was removed or relinked during analysis. Call get_media and retry.")
        } catch let error as ReelAnalyzer.AnalyzeError {
            throw ToolError("Reel analysis failed: \(error.localizedDescription)")
        }

        var out: [String: Any] = [
            "timelineId": receipt.timelineId,
            "mode": mode.rawValue,
            "slotCount": receipt.slotClipIds.count,
        ]
        if mode == .placeholders {
            out["slotClipIds"] = receipt.slotClipIds
            out["note"] = "The template timeline is now active. Call get_timeline to see the slots and audio lanes, then fill_template_slot to place footage."
        }
        if !receipt.warnings.isEmpty {
            out["warnings"] = receipt.warnings.map(\.rawValue)
        }
        guard let json = Self.jsonString(out) else { throw ToolError("Failed to encode result.") }
        return .ok(json)
    }

    func fillTemplateSlot(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.fillTemplateSlotAllowedKeys, path: "fill_template_slot")
        let clipId = try args.requireString("clipId")
        let mediaRef = try args.requireString("mediaRef")
        _ = try asset(mediaRef, editor: editor)

        do {
            try editor.fillTemplateSlot(clipId: clipId, assetId: mediaRef)
        } catch EditorViewModel.TemplateStudioError.notATemplateSlot {
            throw ToolError("Clip \(clipId) is not a template slot on the active timeline.")
        } catch EditorViewModel.TemplateStudioError.notAVideo {
            throw ToolError("fill_template_slot needs a video asset: \(mediaRef) is not a video.")
        }

        guard let location = editor.findClip(id: clipId) else {
            throw ToolError("Slot \(clipId) disappeared after the fill; call get_timeline.")
        }
        let clip = editor.timeline.tracks[location.trackIndex].clips[location.clipIndex]
        let out: [String: Any] = [
            "clipId": clipId,
            "mediaRef": mediaRef,
            "startFrame": clip.startFrame,
            "durationFrames": clip.durationFrames,
            "speed": clip.speed,
        ]
        guard let json = Self.jsonString(out) else { throw ToolError("Failed to encode result.") }
        return .ok(json)
    }

    private static func templateMode(_ args: [String: Any]) throws -> TemplateMode {
        guard let rawMode = args["mode"] as? String else { return .placeholders }
        guard let mode = TemplateMode(rawValue: rawMode) else {
            throw ToolError("Unknown mode '\(rawMode)'. Use 'placeholders' or 'originalCuts'.")
        }
        return mode
    }
}
