import Foundation

struct ParsedTextColorPatch {
    let value: TextStyle.RGBA
    let includesOpacity: Bool
}

struct ParsedTextOutlinePatch {
    let enabled: Bool?
    let color: TextStyle.RGBA?
    let width: Double?

    var hasAnyField: Bool { enabled != nil || color != nil || width != nil }
    var affectsLayout: Bool { enabled != nil || width != nil }
}

struct ParsedTextShadowPatch {
    let enabled: Bool?
    let color: ParsedTextColorPatch?
    let opacity: Double?
    let offsetX: Double?
    let offsetY: Double?
    let blur: Double?

    var hasAnyField: Bool {
        enabled != nil || color != nil || opacity != nil || offsetX != nil || offsetY != nil || blur != nil
    }

    var affectsLayout: Bool {
        enabled != nil || offsetX != nil || offsetY != nil || blur != nil
    }
}

struct ParsedTextBackgroundPatch {
    let enabled: Bool?
    let color: ParsedTextColorPatch?
    let opacity: Double?
    let paddingX: Double?
    let paddingY: Double?
    let offsetX: Double?
    let offsetY: Double?
    let cornerRadius: Double?
    let outlineColor: TextStyle.RGBA?
    let outlineWidth: Double?

    var hasAnyField: Bool {
        enabled != nil || color != nil || opacity != nil || paddingX != nil || paddingY != nil
            || offsetX != nil || offsetY != nil || cornerRadius != nil
            || outlineColor != nil || outlineWidth != nil
    }

    var affectsLayout: Bool { enabled != nil || paddingX != nil || paddingY != nil }
}

struct ParsedTextStylePatch {
    let fontName: String?
    let fontSize: Double?
    let isBold: Bool?
    let isItalic: Bool?
    let isUnderlined: Bool?
    let isStruckThrough: Bool?
    let isOverlined: Bool?
    let tracking: Double?
    let lineSpacing: Double?
    let fontCase: TextStyle.FontCase?
    let color: TextStyle.RGBA?
    let alignment: TextStyle.Alignment?
    let outline: ParsedTextOutlinePatch?
    let shadow: ParsedTextShadowPatch?
    let background: ParsedTextBackgroundPatch?

    var hasAnyField: Bool {
        fontName != nil || fontSize != nil || isBold != nil || isItalic != nil
            || isUnderlined != nil || isStruckThrough != nil || isOverlined != nil
            || tracking != nil || lineSpacing != nil || fontCase != nil
            || color != nil || alignment != nil || outline?.hasAnyField == true
            || shadow?.hasAnyField == true || background?.hasAnyField == true
    }

    var affectsLayout: Bool {
        fontName != nil || fontSize != nil || isBold != nil || isItalic != nil
            || tracking != nil || lineSpacing != nil || fontCase != nil
            || outline?.affectsLayout == true || shadow?.affectsLayout == true
            || background?.affectsLayout == true
    }
}

/// How an add_texts entry resolves its caption group: inherit the track's uniform group by default,
/// opt out explicitly, or join a named group.
fileprivate enum CaptionGroupChoice {
    case inherit
    case none
    case explicit(String)
}

/// What add_texts does when a new clip's span overlaps existing clips on its target track.
fileprivate enum OverlapPolicy: String {
    case clear   // overwrite the region (trim/split/remove existing clips) — the historical behavior
    case fail    // reject the whole call before mutating, listing the colliding clip ids
}

fileprivate struct PartialTextSpec {
    let trackId: String?
    let startFrame: Int
    let durationFrames: Int
    let content: String
    let style: TextStyle
    let transform: Transform?
    let animation: TextAnimation?
    let group: CaptionGroupChoice
}

extension ToolExecutor {
    private static let addTextsAllowedKeys: Set<String> = Set([
        "trackIndex", "startFrame", "endFrame", "content",
        "style", "transform", "animation", "highlightColor", "granularity", "captionGroupId", "onOverlap",
    ])

    private static let updateTextAllowedKeys: Set<String> = Set([
        "clipIds", "captionGroupId", "content", "entries",
        "style", "transform", "animation", "highlightColor", "granularity", "origin",
    ])

    func parseTextStylePatch(_ args: [String: Any], path: String) throws -> ParsedTextStylePatch? {
        guard args.keys.contains("style") else { return nil }
        guard let style = args["style"] as? [String: Any] else {
            throw ToolError("\(path).style: expected object")
        }
        return try parseTextStylePatchObject(style, path: "\(path).style")
    }

    private func parseTextStylePatchObject(_ args: [String: Any], path: String) throws -> ParsedTextStylePatch {
        try validateUnknownKeys(
            args,
            allowed: [
                "fontName", "fontSize", "bold", "italic", "underline", "strikethrough", "overline",
                "tracking", "lineSpacing", "fontCase",
                "color", "alignment", "outline", "shadow", "background",
            ],
            path: path
        )

        let outline = try parseOutlinePatch(args["outline"], path: "\(path).outline")
        let shadow = try parseShadowPatch(args["shadow"], path: "\(path).shadow")
        let background = try parseBackgroundPatch(args["background"], path: "\(path).background")

        return ParsedTextStylePatch(
            fontName: try optionalString(args, key: "fontName", path: path),
            fontSize: try optionalNumber(args, key: "fontSize", path: path, range: 12...300),
            isBold: try optionalBool(args, key: "bold", path: path),
            isItalic: try optionalBool(args, key: "italic", path: path),
            isUnderlined: try optionalBool(args, key: "underline", path: path),
            isStruckThrough: try optionalBool(args, key: "strikethrough", path: path),
            isOverlined: try optionalBool(args, key: "overline", path: path),
            tracking: try optionalNumber(args, key: "tracking", path: path, range: -20...100),
            lineSpacing: try optionalNumber(args, key: "lineSpacing", path: path, range: -100...300),
            fontCase: try parseFontCase(args, path: path),
            color: try optionalColor(args, key: "color", path: path)?.value,
            alignment: try parseTextAlignment(args, path: path),
            outline: outline,
            shadow: shadow,
            background: background
        )
    }

    private func parseOutlinePatch(_ raw: Any?, path: String) throws -> ParsedTextOutlinePatch? {
        guard let raw else { return nil }
        guard let args = raw as? [String: Any] else { throw ToolError("\(path): expected object") }
        try validateUnknownKeys(args, allowed: ["enabled", "color", "width"], path: path)
        return .init(
            enabled: try optionalBool(args, key: "enabled", path: path),
            color: try optionalColor(args, key: "color", path: path)?.value,
            width: try optionalNumber(args, key: "width", path: path, range: 0...40)
        )
    }

    private func parseShadowPatch(_ raw: Any?, path: String) throws -> ParsedTextShadowPatch? {
        guard let raw else { return nil }
        guard let args = raw as? [String: Any] else { throw ToolError("\(path): expected object") }
        try validateUnknownKeys(args, allowed: ["enabled", "color", "opacity", "offset", "blur"], path: path)
        let offset = try optionalPair(args, key: "offset", path: path, range: -200...200)
        return .init(
            enabled: try optionalBool(args, key: "enabled", path: path),
            color: try optionalColor(args, key: "color", path: path),
            opacity: try optionalNumber(args, key: "opacity", path: path, range: 0...1),
            offsetX: offset?.x,
            offsetY: offset?.y,
            blur: try optionalNumber(args, key: "blur", path: path, range: 0...100)
        )
    }

    private func parseBackgroundPatch(_ raw: Any?, path: String) throws -> ParsedTextBackgroundPatch? {
        guard let raw else { return nil }
        guard let args = raw as? [String: Any] else { throw ToolError("\(path): expected object") }
        try validateUnknownKeys(
            args,
            allowed: ["enabled", "color", "opacity", "padding", "center", "cornerRadius", "outline"],
            path: path
        )
        let padding = try optionalPair(args, key: "padding", path: path, range: 0...300)
        let center = try optionalPair(args, key: "center", path: path, range: -500...500)
        let outline = try optionalObject(args, key: "outline", path: path)
        if let outline { try validateUnknownKeys(outline, allowed: ["color", "width"], path: "\(path).outline") }
        return .init(
            enabled: try optionalBool(args, key: "enabled", path: path),
            color: try optionalColor(args, key: "color", path: path),
            opacity: try optionalNumber(args, key: "opacity", path: path, range: 0...1),
            paddingX: padding?.x,
            paddingY: padding?.y,
            offsetX: center?.x,
            offsetY: center?.y,
            cornerRadius: try optionalNumber(args, key: "cornerRadius", path: path, range: 0...300),
            outlineColor: try outline.flatMap { try optionalColor($0, key: "color", path: "\(path).outline")?.value },
            outlineWidth: try outline.flatMap { try optionalNumber($0, key: "width", path: "\(path).outline", range: 0...40) }
        )
    }

    private func optionalColor(_ args: [String: Any], key: String, path: String) throws -> ParsedTextColorPatch? {
        guard args.keys.contains(key) else { return nil }
        guard let raw = args[key] as? String else { throw ToolError("\(path).\(key): expected string") }
        guard let value = try parseColorHex(raw, path: "\(path).\(key)") else { return nil }
        let digits = raw.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "#" })
        return .init(value: value, includesOpacity: digits.count == 8)
    }

    private func optionalString(_ args: [String: Any], key: String, path: String) throws -> String? {
        guard args.keys.contains(key) else { return nil }
        guard let value = args[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError("\(path).\(key): expected non-empty string")
        }
        return value
    }

    private func optionalBool(_ args: [String: Any], key: String, path: String) throws -> Bool? {
        guard args.keys.contains(key) else { return nil }
        guard let value = args[key] as? Bool else { throw ToolError("\(path).\(key): expected boolean") }
        return value
    }

    private func optionalNumber(
        _ args: [String: Any],
        key: String,
        path: String,
        range: ClosedRange<Double>? = nil
    ) throws -> Double? {
        guard args.keys.contains(key) else { return nil }
        guard let value = args.double(key), value.isFinite else {
            throw ToolError("\(path).\(key): expected finite number")
        }
        if let range, !range.contains(value) {
            throw ToolError("\(path).\(key): must be between \(range.lowerBound) and \(range.upperBound)")
        }
        return value
    }

    private func optionalObject(_ args: [String: Any], key: String, path: String) throws -> [String: Any]? {
        guard args.keys.contains(key) else { return nil }
        guard let value = args[key] as? [String: Any] else { throw ToolError("\(path).\(key): expected object") }
        return value
    }

    private func optionalPair(
        _ args: [String: Any],
        key: String,
        path: String,
        range: ClosedRange<Double>
    ) throws -> (x: Double?, y: Double?)? {
        guard let pair = try optionalObject(args, key: key, path: path) else { return nil }
        let pairPath = "\(path).\(key)"
        try validateUnknownKeys(pair, allowed: ["x", "y"], path: pairPath)
        return (
            try optionalNumber(pair, key: "x", path: pairPath, range: range),
            try optionalNumber(pair, key: "y", path: pairPath, range: range)
        )
    }

    private func parseFontCase(_ args: [String: Any], path: String) throws -> TextStyle.FontCase? {
        guard args.keys.contains("fontCase") else { return nil }
        guard let raw = args["fontCase"] as? String, let value = TextStyle.FontCase(rawValue: raw) else {
            throw ToolError("\(path).fontCase: expected mixed, uppercase, or lowercase")
        }
        return value
    }

    private func parseTextAlignment(_ args: [String: Any], path: String) throws -> TextStyle.Alignment? {
        guard args.keys.contains("alignment") else { return nil }
        guard let raw = args["alignment"] as? String else { throw ToolError("\(path).alignment: expected string") }
        return try parseAlignment(raw, path: "\(path).alignment")
    }

    static func applyTextStylePatch(_ patch: ParsedTextStylePatch, to style: inout TextStyle) {
        if let f = patch.fontName { style.fontName = f }
        if let s = patch.fontSize { style.fontSize = s }
        if let b = patch.isBold { style.isBold = b }
        if let i = patch.isItalic { style.isItalic = i }
        if let u = patch.isUnderlined { style.isUnderlined = u }
        if let s = patch.isStruckThrough { style.isStruckThrough = s }
        if let o = patch.isOverlined { style.isOverlined = o }
        if let t = patch.tracking { style.tracking = t }
        if let l = patch.lineSpacing { style.lineSpacing = l }
        if let f = patch.fontCase { style.fontCase = f }
        if let c = patch.color { style.color = c }
        if let a = patch.alignment { style.alignment = a }
        if let outline = patch.outline {
            if let e = outline.enabled { style.border.enabled = e }
            if let c = outline.color { style.border.color = c }
            if let w = outline.width { style.border.width = w }
        }
        if let shadow = patch.shadow {
            if let e = shadow.enabled { style.shadow.enabled = e }
            if let c = shadow.color {
                if c.includesOpacity { style.shadow.color = c.value } else { style.shadow.color.setRGB(from: c.value) }
            }
            if let o = shadow.opacity { style.shadow.color.a = o }
            if let x = shadow.offsetX { style.shadow.offsetX = x }
            if let y = shadow.offsetY { style.shadow.offsetY = y }
            if let b = shadow.blur { style.shadow.blur = b }
        }
        if let background = patch.background {
            if let e = background.enabled { style.background.enabled = e }
            if let c = background.color {
                if c.includesOpacity { style.background.color = c.value } else { style.background.color.setRGB(from: c.value) }
            }
            if let o = background.opacity { style.background.color.a = o }
            if let x = background.paddingX { style.background.paddingX = x }
            if let y = background.paddingY { style.background.paddingY = y }
            if let x = background.offsetX { style.background.offsetX = x }
            if let y = background.offsetY { style.background.offsetY = y }
            if let r = background.cornerRadius { style.background.cornerRadius = r }
            if let c = background.outlineColor { style.background.outlineColor = c }
            if let w = background.outlineWidth { style.background.outlineWidth = w }
        }
    }

    /// Returns a TextAnimation for an agent 'animation' spec, or nil if 'off' or not set.
    func parseTextAnimation(preset raw: String?, highlightColor: String?, granularity: String? = nil, path: String) throws -> TextAnimation? {
        guard let raw, raw != "off" else { return nil }
        guard let preset = TextAnimation.Preset(rawValue: raw), preset != .none else {
            throw ToolError("\(path): animation must be one of \(TextAnimation.Preset.agentValues.joined(separator: ", "))")
        }
        var anim = TextAnimation(preset: preset, granularity: try parseGranularity(granularity, path: path))
        if let hex = try parseColorHex(highlightColor, path: path) { anim.highlight = hex }
        return anim
    }

    private func parseGranularity(_ raw: String?, path: String) throws -> TextAnimation.Granularity {
        guard let raw else { return .word }
        guard let g = TextAnimation.Granularity(rawValue: raw) else {
            throw ToolError("\(path): granularity must be one of word, char")
        }
        return g
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

    /// Resolve an entry's `captionGroupId`: absent → inherit the track's uniform group, "none" → opt
    /// out, any other string → join that existing group (validated).
    fileprivate func parseCaptionGroupChoice(_ editor: EditorViewModel, entry: [String: Any], path: String) throws -> CaptionGroupChoice {
        guard entry.keys.contains("captionGroupId") else { return .inherit }
        guard let raw = entry["captionGroupId"] as? String else {
            throw ToolError("\(path).captionGroupId: expected a string group id or \"none\"")
        }
        if raw == "none" { return .none }
        guard !editor.captionGroupTextClipIds(groupId: raw).isEmpty else {
            throw ToolError("\(path): captionGroupId '\(raw)' has no caption clips")
        }
        return .explicit(raw)
    }

    /// The single caption group every text clip on this track already shares, or nil when the track has
    /// no text clips, mixes groups, or holds ungrouped text. New captions default-join only a uniform group.
    fileprivate func inheritedCaptionGroup(_ editor: EditorViewModel, trackIndex: Int) -> String? {
        guard editor.timeline.tracks.indices.contains(trackIndex) else { return nil }
        let groups = Set(editor.timeline.tracks[trackIndex].clips.filter { $0.mediaType == .text }.map(\.captionGroupId))
        guard groups.count == 1, let group = groups.first, let group else { return nil }
        return group
    }

    func addTexts(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard let rawEntries = args["entries"] as? [Any], !rawEntries.isEmpty else {
            throw ToolError("Missing or empty 'entries' array")
        }

        let onOverlap: OverlapPolicy
        if let raw = args.string("onOverlap") {
            guard let policy = OverlapPolicy(rawValue: raw) else {
                throw ToolError("add_texts.onOverlap: expected 'clear' or 'fail'")
            }
            onOverlap = policy
        } else {
            onOverlap = .clear
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
            if let patch = try parseTextStylePatch(entry, path: path) {
                Self.applyTextStylePatch(patch, to: &style)
            }

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
                animation: try parseTextAnimation(preset: entry.string("animation"), highlightColor: entry.string("highlightColor"), granularity: entry.string("granularity"), path: path),
                group: try parseCaptionGroupChoice(editor, entry: entry, path: path)
            ))
        }

        // All-or-none: a new track at index 0 would shift any explicit indices.
        let omittedCount = partials.filter { $0.trackId == nil }.count
        guard omittedCount == 0 || omittedCount == partials.count else {
            throw ToolError("Mixed trackIndex: \(omittedCount) of \(partials.count) entries omitted trackIndex. Either set it on every entry or omit it on every entry (to auto-create a shared new track).")
        }

        // onOverlap:'fail' validates every entry's span against existing clips BEFORE mutating, so an
        // accidental overwrite never silently deletes clips. A fresh omitted track can't collide.
        if onOverlap == .fail {
            var collisions: [String] = []
            for p in partials {
                guard let tid = p.trackId, let ti = editor.timeline.tracks.firstIndex(where: { $0.id == tid }) else { continue }
                let end = p.startFrame + p.durationFrames
                for clip in editor.timeline.tracks[ti].clips where clip.startFrame < end && clip.endFrame > p.startFrame {
                    collisions.append(clip.id)
                }
            }
            if !collisions.isEmpty {
                let unique = Array(Set(collisions)).sorted()
                throw ToolError("add_texts onOverlap:'fail' — \(unique.count) existing clip(s) intersect the requested spans: \(unique.joined(separator: ", ")). No clips were added.")
            }
        }

        let snapshot = timelineSnapshot(editor)
        let actionName = partials.count == 1 ? "Add Text (Agent)" : "Add Texts (Agent)"
        try editor.undo.perform(actionName) {
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
                let captionGroupId: String?
                switch p.group {
                case .explicit(let gid): captionGroupId = gid
                case .none: captionGroupId = nil
                case .inherit: captionGroupId = inheritedCaptionGroup(editor, trackIndex: trackIdx)
                }
                return .init(
                    trackIndex: trackIdx,
                    startFrame: p.startFrame,
                    durationFrames: p.durationFrames,
                    content: p.content,
                    style: p.style,
                    transform: p.transform,
                    captionGroupId: captionGroupId,
                    animation: p.animation
                )
            }

            let ids = editor.placeTextClips(resolvedSpecs, clearExistingRegions: onOverlap == .clear)
            guard !ids.isEmpty else {
                if let tid = createdTrackId { editor.removeTrack(id: tid) }
                throw ToolError("Failed to place any text clips")
            }

            editor.registerTimelineUndo(actionName) { vm in
                vm.removeClips(ids: Set(ids))
            }
        }
        editor.notifyTimelineChanged()
        return mutationResult(editor, since: snapshot)
    }

    func updateText(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.updateTextAllowedKeys, path: "update_text")

        // Two shapes: legacy (clipIds/captionGroupId + one shared content) or entries ([{clipId, content}],
        // one per-clip content). Both share the style/animation/transform params below.
        var clipIds: [String]
        var contentByClip: [String: String]
        let hasContent: Bool

        if args.keys.contains("entries") {
            guard !args.keys.contains("clipIds"), !args.keys.contains("content"), !args.keys.contains("captionGroupId") else {
                throw ToolError("update_text: 'entries' is mutually exclusive with clipIds, content, and captionGroupId.")
            }
            guard let rawEntries = args["entries"] as? [Any], !rawEntries.isEmpty else {
                throw ToolError("update_text.entries: expected a non-empty array")
            }
            var ids: [String] = []
            var map: [String: String] = [:]
            for (idx, raw) in rawEntries.enumerated() {
                let path = "update_text.entries[\(idx)]"
                guard let entry = raw as? [String: Any] else { throw ToolError("\(path): expected an object") }
                try validateUnknownKeys(entry, allowed: ["clipId", "content"], path: path)
                let clipId = try entry.requireString("clipId")
                guard let text = entry["content"] as? String else { throw ToolError("\(path).content: expected String") }
                guard map[clipId] == nil else { throw ToolError("\(path): duplicate clipId '\(clipId)'") }
                map[clipId] = text
                ids.append(clipId)
            }
            clipIds = ids
            contentByClip = map
            hasContent = true
        } else {
            let content: String?
            if args.keys.contains("content") {
                guard let raw = args["content"] as? String else { throw ToolError("update_text.content: expected String") }
                content = raw
            } else {
                content = nil
            }
            clipIds = args.stringArray("clipIds")
            if let gid = args.string("captionGroupId") {
                let groupIds = editor.captionGroupTextClipIds(groupId: gid)
                guard !groupIds.isEmpty else { throw ToolError("No caption clips found for captionGroupId: \(gid)") }
                var seen = Set(clipIds)
                for id in groupIds where seen.insert(id).inserted { clipIds.append(id) }
            }
            guard !clipIds.isEmpty else { throw ToolError("Provide a non-empty 'clipIds' array, a 'captionGroupId', or 'entries'") }
            hasContent = content != nil
            contentByClip = content.map { c in Dictionary(clipIds.map { ($0, c) }, uniquingKeysWith: { a, _ in a }) } ?? [:]
        }

        let textStylePatch = try parseTextStylePatch(args, path: "update_text")
        let transform = try parseUpdateTextTransform(args["transform"] as? [String: Any], path: "update_text")
        let animation = try parseTextAnimation(preset: args.string("animation"), highlightColor: args.string("highlightColor"), granularity: args.string("granularity"), path: "update_text")
        let shouldSetAnimation = args.string("animation") != nil
        let highlightOnly = shouldSetAnimation ? nil : try parseColorHex(args.string("highlightColor"), path: "update_text")

        guard hasContent || textStylePatch?.hasAnyField == true || transform != nil || shouldSetAnimation || highlightOnly != nil else {
            throw ToolError("update_text needs at least one text property to apply")
        }

        for id in clipIds {
            guard let loc = editor.findClip(id: id) else { throw ToolError("Clip not found: \(id)") }
            let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            guard clip.mediaType == .text else {
                throw ToolError("update_text only applies to text clips: \(id) is \(clip.mediaType.rawValue)")
            }
        }

        // origin=user is the promotable path; resync (programmatic caption rewrites) is excluded (§5.3 loop guard).
        let origin = args.string("origin") ?? "user"
        guard ["user", "resync"].contains(origin) else {
            throw ToolError("update_text.origin: expected 'user' or 'resync'")
        }

        var notes: [String] = []
        // Snapshot each clip's old→new content before mutation so we can classify term corrections after.
        // Ordered by clipIds so the first non-promoted reason (D3) is deterministic.
        var contentEdits: [(clipId: String, old: String, new: String, grouped: Bool)] = []
        if hasContent, origin == "user" {
            for id in clipIds {
                guard let target = contentByClip[id], let loc = editor.findClip(id: id) else { continue }
                let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
                guard let old = clip.textContent, old != target else { continue }
                contentEdits.append((id, old, target, clip.captionGroupId != nil))
            }
        }
        let snapshot = timelineSnapshot(editor)
        let actionName = clipIds.count == 1 ? "Update Text (Agent)" : "Update Texts (Agent)"
        let shouldFitToContent = transform == nil && (hasContent || textStylePatch?.affectsLayout == true)
        let canvasW = Double(editor.timeline.width)
        let canvasH = Double(editor.timeline.height)
        var promoted: [[String: Any]] = []
        var promotedStrings: [String] = []
        var promotedClipIds = Set<String>()
        var clearedTimings = 0
        editor.undo.perform(actionName) {
            editor.commitClipProperties(clipIds: clipIds) { clip in
                if let target = contentByClip[clip.id] {
                    // Re-align surviving word timings instead of dropping them; only a rewrite with
                    // no anchor clears wholesale.
                    if clip.setCaptionContent(target) { clearedTimings += 1 }
                }
                if let textStylePatch, textStylePatch.hasAnyField {
                    var style = clip.textStyle ?? TextStyle()
                    Self.applyTextStylePatch(textStylePatch, to: &style)
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
                        current.granularity = animation.granularity
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

            // Auto-promote clean single-substitution caption edits into the glossary (no confirmation). §6
            for edit in contentEdits where edit.grouped {
                guard case let .promote(promotion) = GlossaryClassifier.classifyWithReason(old: edit.old, new: edit.new),
                      let row = promoteCaptionEdit(promotion, clipId: edit.clipId, editor: editor) else { continue }
                promoted.append(row)
                promotedStrings.append(contentsOf: [promotion.canonical, promotion.variant])
                promotedClipIds.insert(edit.clipId)
                // §5.1: the term now materialises in L1/L2, so this caption is generated again,
                // not an override — mark it clean or every later resync logs a false conflict.
                editor.commitClipProperties(clipIds: [edit.clipId]) { $0.generatedText = edit.new }
            }
        }

        // D3: name why the FIRST content edit that didn't promote was left alone — one note, not per-clip.
        for edit in contentEdits where !promotedClipIds.contains(edit.clipId) {
            let reason: GlossaryClassifier.RejectReason?
            if !edit.grouped {
                reason = .noCaptionGroup
            } else if case let .reject(r) = GlossaryClassifier.classifyWithReason(old: edit.old, new: edit.new) {
                reason = r
            } else {
                reason = nil  // classifier promotes it but validation dropped the variant — rare; skip.
            }
            if let reason {
                notes.append("Caption edit on \(edit.clipId) not promoted to glossary: \(reason.note).")
                break
            }
        }

        // §5.2: update every other caption that still shows a promoted variant.
        if !promotedStrings.isEmpty {
            editor.resyncCaptionsForGlossaryTerm(strings: promotedStrings, trigger: "glossary_promotion")
        }

        if clearedTimings > 0 {
            notes.append("Rewrote \(clearedTimings) caption\(clearedTimings == 1 ? "" : "s") with no surviving word — karaoke timing there was cleared and falls back to plain text.")
        }

        var extra: [String: Any] = [:]
        if !promoted.isEmpty { extra["promoted"] = promoted }
        return mutationResult(editor, since: snapshot, touched: clipIds, extra: extra, notes: notes)
    }
}
