import Foundation

struct ParsedTextStylePatch {
    let fontName: String?
    let fontSize: Double?
    let isBold: Bool?
    let isItalic: Bool?
    let color: TextStyle.RGBA?
    let alignment: TextStyle.Alignment?
    let borderColor: TextStyle.RGBA?
    let backgroundColor: TextStyle.RGBA?

    var hasAnyField: Bool {
        fontName != nil || fontSize != nil || isBold != nil || isItalic != nil
            || color != nil || alignment != nil
            || borderColor != nil
            || backgroundColor != nil
    }

    var affectsLayout: Bool {
        fontName != nil || fontSize != nil || isBold != nil || isItalic != nil
    }
}

let agentTextStylePatchAllowedKeys: Set<String> = [
    "fontName", "fontSize", "isBold", "isItalic", "color", "alignment",
    "borderColor", "backgroundColor",
]

fileprivate struct PartialTextSpec {
    let trackId: String?
    let startFrame: Int
    let durationFrames: Int
    let content: String
    let style: TextStyle
    let transform: Transform?
    let animation: TextAnimation?
}

extension ToolExecutor {
    private static let addTextsAllowedKeys: Set<String> = Set([
        "trackIndex", "startFrame", "endFrame", "content",
        "transform", "animation", "highlightColor",
    ]).union(agentTextStylePatchAllowedKeys)

    private static let updateTextAllowedKeys: Set<String> = Set([
        "clipIds", "captionGroupId", "content",
        "transform", "animation", "highlightColor",
    ]).union(agentTextStylePatchAllowedKeys)

    func parseTextStylePatch(_ args: [String: Any], path: String) throws -> ParsedTextStylePatch {
        return ParsedTextStylePatch(
            fontName: args.string("fontName"),
            fontSize: args.double("fontSize"),
            isBold: args.bool("isBold"),
            isItalic: args.bool("isItalic"),
            color: try parseColorHex(args.string("color"), path: "\(path).color"),
            alignment: try parseAlignment(args.string("alignment"), path: path),
            borderColor: try parseColorHex(args.string("borderColor"), path: "\(path).borderColor"),
            backgroundColor: try parseColorHex(args.string("backgroundColor"), path: "\(path).backgroundColor")
        )
    }

    static func applyTextStylePatch(_ patch: ParsedTextStylePatch, to style: inout TextStyle) -> [String] {
        var changed: [String] = []
        if let f = patch.fontName { style.fontName = f; changed.append("fontName") }
        if let s = patch.fontSize { style.fontSize = s; changed.append("fontSize") }
        if let b = patch.isBold { style.isBold = b; changed.append("isBold") }
        if let i = patch.isItalic { style.isItalic = i; changed.append("isItalic") }
        if let c = patch.color { style.color = c; changed.append("color") }
        if let a = patch.alignment { style.alignment = a; changed.append("alignment") }
        if let c = patch.borderColor {
            style.border.color = c
            style.border.enabled = true
            changed.append("borderColor")
        }
        if let c = patch.backgroundColor {
            style.background.color = c
            style.background.enabled = true
            changed.append("backgroundColor")
        }
        return changed
    }

    /// Returns a TextAnimation for an agent 'animation' spec, or nil if 'off' or not set.
    func parseTextAnimation(preset raw: String?, highlightColor: String?, path: String) throws -> TextAnimation? {
        guard let raw, raw != "off" else { return nil }
        guard let preset = TextAnimation.Preset(rawValue: raw), preset != .none else {
            throw ToolError("\(path): animation must be one of \(TextAnimation.Preset.agentValues.joined(separator: ", "))")
        }
        var anim = TextAnimation(preset: preset)
        if let hex = try parseColorHex(highlightColor, path: path) { anim.highlight = hex }
        return anim
    }

    private func parseAddTextTransform(
        _ tDict: [String: Any]?,
        content: String, style: TextStyle,
        canvas: (w: Double, h: Double),
        path: String
    ) throws -> Transform? {
        guard let tDict else { return nil }
        try validateUnknownKeys(tDict, allowed: ["centerX", "centerY", "width", "height"], path: "\(path).transform")
        let cX = tDict.double("centerX"), cY = tDict.double("centerY")
        let w = tDict.double("width"), h = tDict.double("height")
        if cX == nil && cY == nil && w == nil && h == nil { return nil }
        guard let cx = cX, let cy = cY else {
            throw ToolError("\(path): transform must be either {centerX, centerY} for auto-fit, or all four of {centerX, centerY, width, height}")
        }
        if let ww = w, let hh = h {
            return Transform(center: (cx, cy), width: ww, height: hh)
        }
        guard w == nil && h == nil else {
            throw ToolError("\(path): transform must be either {centerX, centerY} for auto-fit, or all four of {centerX, centerY, width, height}")
        }
        let natural = TextLayout.naturalSize(content: content, style: style, maxWidth: CGFloat(canvas.w) * 0.9, canvasHeight: CGFloat(canvas.h))
        return Transform(center: (cx, cy), width: Double(natural.width) / canvas.w, height: Double(natural.height) / canvas.h)
    }

    private func parseUpdateTextTransform(_ tDict: [String: Any]?, path: String) throws -> ParsedTransform? {
        guard let tDict else { return nil }
        try validateUnknownKeys(tDict, allowed: ["centerX", "centerY", "width", "height"], path: "\(path).transform")
        let transform = ParsedTransform(
            centerX: tDict.double("centerX"),
            centerY: tDict.double("centerY"),
            width: tDict.double("width"),
            height: tDict.double("height"),
            flipHorizontal: nil,
            flipVertical: nil
        )
        return transform.hasAnyField ? transform : nil
    }

    func addTexts(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard let rawEntries = args["entries"] as? [Any], !rawEntries.isEmpty else {
            throw ToolError("Missing or empty 'entries' array")
        }

        var partials: [PartialTextSpec] = []
        partials.reserveCapacity(rawEntries.count)

        for (idx, raw) in rawEntries.enumerated() {
            let path = "entries[\(idx)]"
            guard let entry = raw as? [String: Any] else {
                throw ToolError("\(path) must be an object")
            }
            try validateUnknownKeys(entry, allowed: Self.addTextsAllowedKeys, path: path)

            let trackIndex = entry.int("trackIndex")
            let startFrame = try entry.requireInt("startFrame")
            let endFrame = try entry.requireInt("endFrame")
            let content = try entry.requireString("content")

            var trackId: String? = nil
            if let ti = trackIndex {
                guard editor.timeline.tracks.indices.contains(ti) else {
                    throw ToolError("\(path): track index \(ti) out of range (0..\(editor.timeline.tracks.count - 1))")
                }
                guard ClipType.text.isCompatible(with: editor.timeline.tracks[ti].type) else {
                    throw ToolError("\(path): track \(ti) is an audio track; text requires a video/image/text track")
                }
                trackId = editor.timeline.tracks[ti].id
            }
            guard startFrame >= 0 else {
                throw ToolError("\(path): startFrame must be >= 0 (got \(startFrame))")
            }
            guard endFrame > startFrame else {
                throw ToolError("\(path): endFrame (\(endFrame)) must be greater than startFrame (\(startFrame))")
            }
            let durationFrames = endFrame - startFrame

            var style = TextStyle()
            _ = Self.applyTextStylePatch(try parseTextStylePatch(entry, path: path), to: &style)

            let transform = try parseAddTextTransform(
                entry["transform"] as? [String: Any],
                content: content, style: style,
                canvas: (Double(editor.timeline.width), Double(editor.timeline.height)),
                path: path
            )

            partials.append(.init(
                trackId: trackId,
                startFrame: startFrame,
                durationFrames: durationFrames,
                content: content,
                style: style,
                transform: transform,
                animation: try parseTextAnimation(preset: entry.string("animation"), highlightColor: entry.string("highlightColor"), path: path)
            ))
        }

        // All-or-none: a new track at index 0 would shift any explicit indices.
        let omittedCount = partials.filter { $0.trackId == nil }.count
        guard omittedCount == 0 || omittedCount == partials.count else {
            throw ToolError("Mixed trackIndex: \(omittedCount) of \(partials.count) entries omitted trackIndex. Either set it on every entry or omit it on every entry (to auto-create a shared new track).")
        }

        let snapshot = timelineSnapshot(editor)
        let actionName = partials.count == 1 ? "Add Text (Agent)" : "Add Texts (Agent)"
        try withUndoGroup(editor, actionName: actionName) {
            var createdTrackId: String? = nil
            let resolvedTrackId: String?
            if omittedCount == partials.count {
                let newIdx = editor.insertTrack(at: 0, type: .video)
                createdTrackId = editor.timeline.tracks.indices.contains(newIdx) ? editor.timeline.tracks[newIdx].id : nil
                resolvedTrackId = createdTrackId
            } else {
                resolvedTrackId = nil  // each partial already has its own trackId
            }

            let resolvedSpecs: [EditorViewModel.TextClipSpec] = partials.compactMap { p in
                let id = resolvedTrackId ?? p.trackId
                guard let id, let trackIdx = editor.timeline.tracks.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                return .init(
                    trackIndex: trackIdx,
                    startFrame: p.startFrame,
                    durationFrames: p.durationFrames,
                    content: p.content,
                    style: p.style,
                    transform: p.transform,
                    animation: p.animation
                )
            }

            let ids = editor.placeTextClips(resolvedSpecs)
            guard !ids.isEmpty else {
                if let tid = createdTrackId { editor.removeTrack(id: tid) }
                throw ToolError("Failed to place any text clips")
            }

            editor.registerTimelineUndo { vm in
                vm.removeClips(ids: Set(ids))
            }
        }
        editor.notifyTimelineChanged()
        return mutationResult(editor, since: snapshot)
    }

    func updateText(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.updateTextAllowedKeys, path: "update_text")

        let hasContent = args.keys.contains("content")
        let content: String?
        if hasContent {
            guard let raw = args["content"] as? String else {
                throw ToolError("update_text.content: expected String")
            }
            content = raw
        } else {
            content = nil
        }

        var clipIds = args.stringArray("clipIds")
        if let gid = args.string("captionGroupId") {
            let groupIds = editor.captionGroupTextClipIds(groupId: gid)
            guard !groupIds.isEmpty else { throw ToolError("No caption clips found for captionGroupId: \(gid)") }
            var seen = Set(clipIds)
            for id in groupIds where seen.insert(id).inserted { clipIds.append(id) }
        }
        guard !clipIds.isEmpty else { throw ToolError("Provide a non-empty 'clipIds' array or a 'captionGroupId'") }

        let textStylePatch = try parseTextStylePatch(args, path: "update_text")
        let transform = try parseUpdateTextTransform(args["transform"] as? [String: Any], path: "update_text")
        let animation = try parseTextAnimation(preset: args.string("animation"), highlightColor: args.string("highlightColor"), path: "update_text")
        let shouldSetAnimation = args.string("animation") != nil
        let highlightOnly = shouldSetAnimation ? nil : try parseColorHex(args.string("highlightColor"), path: "update_text")

        guard hasContent || textStylePatch.hasAnyField || transform != nil || shouldSetAnimation || highlightOnly != nil else {
            throw ToolError("update_text needs at least one text property to apply")
        }

        for id in clipIds {
            guard let loc = editor.findClip(id: id) else { throw ToolError("Clip not found: \(id)") }
            let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            guard clip.mediaType == .text else {
                throw ToolError("update_text only applies to text clips: \(id) is \(clip.mediaType.rawValue)")
            }
        }

        var notes: [String] = []
        if hasContent {
            let timingCleared = clipIds.filter { id in
                guard let loc = editor.findClip(id: id) else { return false }
                let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
                return clip.wordTimings != nil && clip.textContent != content
            }
            if !timingCleared.isEmpty {
                notes.append("Content change cleared word timings on \(timingCleared.count) clip\(timingCleared.count == 1 ? "" : "s") — karaoke highlighting falls back to plain text there.")
            }
        }

        let snapshot = timelineSnapshot(editor)
        let actionName = clipIds.count == 1 ? "Update Text (Agent)" : "Update Texts (Agent)"
        let shouldFitToContent = transform == nil && (hasContent || textStylePatch.affectsLayout)
        let canvasW = Double(editor.timeline.width)
        let canvasH = Double(editor.timeline.height)
        withUndoGroup(editor, actionName: actionName) {
            editor.commitClipProperties(clipIds: clipIds) { clip in
                if let content {
                    if clip.textContent != content {
                        clip.wordTimings = nil
                    }
                    clip.textContent = content
                }
                if textStylePatch.hasAnyField {
                    var style = clip.textStyle ?? TextStyle()
                    _ = Self.applyTextStylePatch(textStylePatch, to: &style)
                    clip.textStyle = style
                }
                if let t = transform {
                    let cur = clip.transform
                    var next = Transform(
                        center: (t.centerX ?? cur.center.x, t.centerY ?? cur.center.y),
                        width: t.width ?? cur.width,
                        height: t.height ?? cur.height
                    )
                    next.rotation = cur.rotation
                    next.flipHorizontal = cur.flipHorizontal
                    next.flipVertical = cur.flipVertical
                    clip.transform = next
                }
                if shouldSetAnimation {
                    if let animation {
                        var current = clip.textAnimation ?? TextAnimation()
                        current.preset = animation.preset
                        if let highlight = animation.highlight {
                            current.highlight = highlight
                        }
                        clip.textAnimation = current
                    } else {
                        clip.textAnimation = nil
                    }
                }
                if let hl = highlightOnly {
                    var a = clip.textAnimation ?? TextAnimation()
                    a.highlight = hl
                    clip.textAnimation = a
                }
                if shouldFitToContent {
                    _ = editor.fitTextClipToContentIfNeeded(&clip, canvasW: canvasW, canvasH: canvasH)
                }
            }
        }

        return mutationResult(editor, since: snapshot, touched: clipIds, notes: notes)
    }
}
