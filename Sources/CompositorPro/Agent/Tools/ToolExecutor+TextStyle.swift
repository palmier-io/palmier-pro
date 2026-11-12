import Foundation

extension ToolExecutor {
    private struct ApplyTextStyleInput: DecodableToolArgs {
        var preset: String?
        var clipIds: [String]?
        var captionGroupId: String?
        var fontName: String?
        var fontSize: Double?
        var color: String?
        var alignment: String?
        var applyPosition: Bool?
        var platform: String?

        static let allowedKeys: Set<String> = [
            "preset", "clipIds", "captionGroupId", "fontName", "fontSize", "color",
            "alignment", "applyPosition", "platform",
        ]
    }

    /// Applies a named type style to text, captions, or a caption group.
    func applyTextStyle(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(
            args, allowed: ApplyTextStyleInput.allowedKeys, path: "apply_text_style"
        )
        let input: ApplyTextStyleInput = try decodeToolArgs(args, path: "apply_text_style")

        guard let presetID = input.preset, !presetID.isEmpty else {
            let known = TextStylePresets.all.map(\.id).joined(separator: ", ")
            throw ToolError("apply_text_style: preset is required. Available: \(known).")
        }
        guard let preset = TextStylePresets.preset(id: presetID) else {
            let known = TextStylePresets.all.map(\.id).joined(separator: ", ")
            throw ToolError("apply_text_style: unknown preset '\(presetID)'. Available: \(known).")
        }

        var clipIds = input.clipIds ?? []
        let captionGroupId = input.captionGroupId
        if let group = captionGroupId {
            let members = editor.captionGroupTextClipIds(groupId: group)
            guard !members.isEmpty else {
                throw ToolError("apply_text_style: no caption group '\(group)'.")
            }
            clipIds.append(contentsOf: members)
        }
        // Deduplicate so a clip named both directly and via its group is styled once.
        var ordered: [String] = []
        for id in clipIds where !ordered.contains(id) { ordered.append(id) }
        guard !ordered.isEmpty else {
            throw ToolError(
                "apply_text_style: pass clipIds, or captionGroupId to restyle a caption track "
                    + "as one unit. get_timeline lists caption groups."
            )
        }

        // Short ids are what receipts hand out, so expand them the same way every tool does.
        let expanded = try expandingIdPrefixes(
            in: ["clipIds": ordered], editor: editor
        ).stringArray("clipIds") ?? ordered
        guard editor.clipFor(id: expanded.first ?? "") != nil else {
            throw ToolError("apply_text_style: none of those clips exist. Re-read with get_timeline.")
        }

        let platform = try deliveryPlatform(input.platform, path: "apply_text_style.platform")
        let canvasHeight = editor.timeline.height
        var style = preset.resolved(canvasHeight: canvasHeight)
        if let fontName = input.fontName, !fontName.isEmpty { style.fontName = fontName }
        if let fontSize = input.fontSize {
            guard fontSize.isFinite, (12 ... 300).contains(fontSize) else {
                throw ToolError("apply_text_style: fontSize must be between 12 and 300.")
            }
            style.fontSize = fontSize
        }
        if let raw = input.color, !raw.isEmpty {
            guard let color = TextStyle.RGBA(hex: raw) else {
                throw ToolError("apply_text_style: color must look like '#RRGGBB' or '#RRGGBBAA'.")
            }
            style.color = color
        }
        if let raw = input.alignment, !raw.isEmpty {
            guard let alignment = TextStyle.Alignment(rawValue: raw) else {
                throw ToolError(
                    "apply_text_style: alignment must be left, center or right; got '\(raw)'."
                )
            }
            style.alignment = alignment
        }

        // The preset's own position is honoured unless the platform's interface is in the way, so
        // captions do not land under it.
        let presetCentre = preset.center
        let clamped = DeliveryPlatform.CaptionPlacement(
            centerX: presetCentre.x, centerY: presetCentre.y, maxWidth: 1
        ).clamped(into: platform.coveredArea)

        let receipt = try await editor.applyTextStyle(
            clipIds: expanded,
            style: style,
            position: input.applyPosition == true
                ? CGPoint(x: CGFloat(clamped.centerX), y: CGFloat(clamped.centerY))
                : nil
        )

        var notes = [
            "Applied '\(preset.id)' at \(Int(style.fontSize))pt for a \(canvasHeight)px canvas "
                + "(\(preset.fontName)).",
            "A preset fixes the decisions that should not vary between clips. Anything it does not "
                + "cover — animation, fill, motion — stays as you set it.",
        ]
        if input.applyPosition == true, platform != .generic {
            notes.append(
                "Position was clamped clear of the \(platform.rawValue) interface, which covers "
                    + "part of the frame."
            )
        }
        if let group = captionGroupId {
            notes.append("Styled \(expanded.count) clips in caption group '\(group)' together.")
        }

        return .ok(Self.jsonString([
            "preset": preset.id,
            "clipIds": receipt.clipIds,
            "styledCount": receipt.styledCount,
            "skipped": receipt.skipped,
            "fontName": style.fontName,
            "fontSize": style.fontSize,
            "fontSizeRatio": preset.sizeRatio,
            "positionApplied": input.applyPosition == true,
            "changed": receipt.styledCount > 0,
            "undoSteps": 1,
            "notes": notes,
        ]) ?? "{}")
    }
}