import Foundation

extension ToolExecutor {
    private struct CaptionTemplatesInput: DecodableToolArgs {
        let action: String?
        let format: String?
        let templateId: String?
        let trackIndex: Int?
        let clipIds: [String]?

        static let allowedKeys: Set<String> = [
            "action", "format", "templateId", "trackIndex", "clipIds",
        ]
    }

    /// Handles caption_templates tool: social format caption template library & batch application.
    func captionTemplates(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: CaptionTemplatesInput = try decodeToolArgs(args, path: "caption_templates")
        let action = input.action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "list"

        switch action {
        case "list":
            let formatFilter = input.format
            let templates = CaptionTemplateLibrary.list(format: formatFilter)
            let response: [String: Any] = [
                "templates": templates.map { t in
                    var dict: [String: Any] = [
                        "id": t.id,
                        "displayName": t.displayName,
                        "format": t.format.rawValue,
                        "formatLabel": t.formatLabel,
                        "targetPlatforms": t.targetPlatforms,
                        "fontName": t.fontName,
                        "fontSizeRatio": t.fontSizeRatio,
                        "isBold": t.isBold,
                        "fontCase": t.fontCase,
                        "alignment": t.alignment,
                        "colorHex": t.colorHex,
                        "outlineWidth": t.outlineWidth,
                        "outlineColorHex": t.outlineColorHex,
                        "background": t.background,
                        "shadow": t.shadow,
                        "animationPreset": t.animationPreset,
                        "centerYRatio": t.centerYRatio,
                        "intent": t.intent,
                        "previewThumbnail": [
                            "sampleText": t.previewThumbnail.sampleText,
                            "badgeLabel": t.previewThumbnail.badgeLabel,
                            "aspectRatio": t.previewThumbnail.aspectRatio,
                            "colorHex": t.previewThumbnail.colorHex,
                            "visualSummary": t.previewThumbnail.visualSummary,
                        ] as [String: Any],
                    ]
                    if let highlight = t.highlightColorHex {
                        dict["highlightColorHex"] = highlight
                    }
                    if let bgHex = t.previewThumbnail.backgroundHex {
                        var thumb = dict["previewThumbnail"] as? [String: Any] ?? [:]
                        thumb["backgroundHex"] = bgHex
                        dict["previewThumbnail"] = thumb
                    }
                    return dict
                },
                "formatFilter": formatFilter ?? "all",
                "count": templates.count,
            ]
            let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
            return .ok(String(decoding: data, as: UTF8.self))

        case "get":
            guard let templateId = input.templateId, !templateId.isEmpty else {
                throw ToolError("caption_templates get action requires templateId.")
            }
            guard let template = CaptionTemplateLibrary.template(id: templateId) else {
                throw ToolError("Caption template '\(templateId)' not found. Available templates: \(CaptionTemplateLibrary.availableIds()).")
            }
            let data = try JSONEncoder().encode(template)
            return .ok(String(decoding: data, as: UTF8.self))

        case "apply":
            guard let templateId = input.templateId, !templateId.isEmpty else {
                throw ToolError("caption_templates apply action requires templateId.")
            }
            let socialFormat = input.format.map { SocialCaptionFormat.resolve($0) }
            do {
                let receipt = try editor.applyCaptionTemplate(
                    templateId: templateId,
                    format: socialFormat,
                    trackIndex: input.trackIndex,
                    clipIds: input.clipIds
                )
                let data = try JSONEncoder().encode(receipt)
                return .ok(String(decoding: data, as: UTF8.self))
            } catch let err as CaptionTemplateError {
                throw ToolError(err.localizedDescription)
            }

        default:
            throw ToolError("caption_templates requires a valid action ('list', 'get', 'apply').")
        }
    }
}

