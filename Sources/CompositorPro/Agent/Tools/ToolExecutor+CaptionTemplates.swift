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
            "template_id", "style", "styleId", "style_id", "template",
            "format_filter", "filter", "category", "type",
            "track_index", "clip_ids", "name", "id",
        ]

        enum CodingKeys: String, CodingKey {
            case action, format, templateId, trackIndex, clipIds
            case template_id, style, styleId, style_id, template
            case format_filter, filter, category, type
            case track_index, clip_ids, name, id
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            action = try container.decodeIfPresent(String.self, forKey: .action)

            var fmt = try container.decodeIfPresent(String.self, forKey: .format)
            if fmt == nil { fmt = try container.decodeIfPresent(String.self, forKey: .format_filter) }
            if fmt == nil { fmt = try container.decodeIfPresent(String.self, forKey: .filter) }
            if fmt == nil { fmt = try container.decodeIfPresent(String.self, forKey: .category) }
            if fmt == nil { fmt = try container.decodeIfPresent(String.self, forKey: .type) }
            format = fmt

            var tid = try container.decodeIfPresent(String.self, forKey: .templateId)
            if tid == nil { tid = try container.decodeIfPresent(String.self, forKey: .template_id) }
            if tid == nil { tid = try container.decodeIfPresent(String.self, forKey: .style) }
            if tid == nil { tid = try container.decodeIfPresent(String.self, forKey: .styleId) }
            if tid == nil { tid = try container.decodeIfPresent(String.self, forKey: .style_id) }
            if tid == nil { tid = try container.decodeIfPresent(String.self, forKey: .template) }
            if tid == nil { tid = try container.decodeIfPresent(String.self, forKey: .name) }
            if tid == nil { tid = try container.decodeIfPresent(String.self, forKey: .id) }
            templateId = tid

            var trk = try container.decodeIfPresent(Int.self, forKey: .trackIndex)
            if trk == nil { trk = try container.decodeIfPresent(Int.self, forKey: .track_index) }
            trackIndex = trk

            var cids = try container.decodeIfPresent([String].self, forKey: .clipIds)
            if cids == nil { cids = try container.decodeIfPresent([String].self, forKey: .clip_ids) }
            clipIds = cids
        }
    }

    /// Handles caption_templates tool: social format caption template library & batch application.
    func captionTemplates(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: CaptionTemplatesInput = try decodeToolArgs(args, path: "caption_templates")
        var rawAction = input.action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if rawAction == nil || rawAction?.isEmpty == true {
            if let templateId = input.templateId, !templateId.isEmpty {
                if input.trackIndex != nil || input.clipIds != nil {
                    rawAction = "apply"
                } else {
                    rawAction = "get"
                }
            } else {
                rawAction = "list"
            }
        }

        let action: String
        switch rawAction {
        case "list", "list_templates", "styles", "list_styles", "all", "templates", "browse", "search":
            action = "list"
        case "get", "inspect", "read", "show", "preview", "view", "detail", "info":
            action = "get"
        case "apply", "set", "select", "use":
            action = "apply"
        default:
            action = rawAction ?? "list"
        }

        switch action {
        case "list":
            let formatFilter = input.format
            var templates = CaptionTemplateLibrary.list(format: formatFilter)
            if let targetId = input.templateId, !targetId.isEmpty,
               let match = CaptionTemplateLibrary.template(id: targetId) {
                templates = [match]
            }
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
            guard let template = CaptionTemplateLibrary.template(id: templateId) else {
                throw ToolError("Caption template '\(templateId)' not found. Available templates: \(CaptionTemplateLibrary.availableIds()).")
            }
            let socialFormat = input.format.map { SocialCaptionFormat.resolve($0) }
            do {
                let receipt = try editor.applyCaptionTemplate(
                    templateId: template.id,
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

