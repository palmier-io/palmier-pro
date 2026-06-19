import Foundation

// MARK: - Input shapes (Decodable)

fileprivate struct AddClipsInput: DecodableToolArgs {
    let entries: [Entry]
    static let allowedKeys: Set<String> = ["entries"]

    struct Entry: DecodableToolArgs {
        let mediaRef: String
        let trackIndex: Int?
        let startFrame: Int
        let durationFrames: Int
        static let allowedKeys: Set<String> = ["mediaRef", "trackIndex", "startFrame", "durationFrames"]
    }
}

fileprivate struct MoveClipsInput: DecodableToolArgs {
    let moves: [Move]
    static let allowedKeys: Set<String> = ["moves"]

    struct Move: DecodableToolArgs {
        let clipId: String
        let toTrack: Int?
        let toFrame: Int?
        static let allowedKeys: Set<String> = ["clipId", "toTrack", "toFrame"]
    }
}

fileprivate struct SetClipPropertiesInput: DecodableToolArgs {
    let clipIds: [String]
    let durationFrames: Int?
    let trimStartFrame: Int?
    let trimEndFrame: Int?
    let speed: Double?
    let volume: Double?
    let opacity: Double?
    let transform: ParsedTransform?
    let content: String?
    let fontName: String?
    let fontSize: Double?
    let color: String?
    let alignment: String?

    static let allowedKeys: Set<String> = [
        "clipIds",
        "durationFrames", "trimStartFrame", "trimEndFrame", "speed",
        "volume", "opacity",
        "transform",
        "content", "fontName", "fontSize", "color", "alignment",
    ]

    var hasAnyProperty: Bool {
        durationFrames != nil || trimStartFrame != nil || trimEndFrame != nil
            || speed != nil || volume != nil || opacity != nil
            || transform != nil
            || content != nil || fontName != nil || fontSize != nil
            || color != nil || alignment != nil
    }
}

fileprivate struct RippleDeleteRangesInput: DecodableToolArgs {
    let clipId: String
    let ranges: [[Double]]
    let units: String?
    static let allowedKeys: Set<String> = ["clipId", "ranges", "units"]
}

fileprivate struct SetKeyframesInput: DecodableToolArgs {
    let clipId: String
    let property: String
    static let allowedKeys: Set<String> = ["clipId", "property", "keyframes"]
}

/// Partial transform shared between set_clip_properties and add_texts.
struct ParsedTransform: Decodable {
    var centerX: Double?
    var centerY: Double?
    var width: Double?
    var height: Double?
    var flipHorizontal: Bool?
    var flipVertical: Bool?

    var hasAnyField: Bool {
        centerX != nil || centerY != nil || width != nil || height != nil
            || flipHorizontal != nil || flipVertical != nil
    }
}

fileprivate struct AddClipSpec {
    let asset: MediaAsset
    var trackId: String?
    let startFrame: Int
    let durationFrames: Int
}

fileprivate struct ParsedMove {
    let clipId: String
    let destTrackId: String?
    let toFrame: Int?
}

// MARK: - Handlers

extension ToolExecutor {

    // MARK: add_clips

    func addClips(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: AddClipsInput = try decodeToolArgs(args, path: "add_clips")
        guard !input.entries.isEmpty else { throw ToolError("Missing or empty 'entries' array") }
        // Decodable doesn't reject unknown nested keys; check each raw entry.
        if let raws = args["entries"] as? [Any] {
            for (idx, raw) in raws.enumerated() {
                if let d = raw as? [String: Any] {
                    try validateUnknownKeys(d, allowed: AddClipsInput.Entry.allowedKeys, path: "entries[\(idx)]")
                }
            }
        }

        var specs: [AddClipSpec] = []
        specs.reserveCapacity(input.entries.count)
        for (idx, entry) in input.entries.enumerated() {
            let asset = try asset(entry.mediaRef, editor: editor)
            var trackId: String? = nil
            if let ti = entry.trackIndex {
                guard editor.timeline.tracks.indices.contains(ti) else {
                    throw ToolError("entries[\(idx)]: track index \(ti) out of range (0..\(editor.timeline.tracks.count - 1))")
                }
                let targetType = editor.timeline.tracks[ti].type
                guard asset.type.isCompatible(with: targetType) else {
                    throw ToolError("entries[\(idx)]: asset type \(asset.type.rawValue) is not compatible with \(targetType.rawValue) track at index \(ti)")
                }
                trackId = editor.timeline.tracks[ti].id
            }
            guard entry.durationFrames >= 1 else {
                throw ToolError("entries[\(idx)]: durationFrames must be >= 1 (got \(entry.durationFrames))")
            }
            guard entry.startFrame >= 0 else {
                throw ToolError("entries[\(idx)]: startFrame must be >= 0 (got \(entry.startFrame))")
            }
            specs.append(.init(asset: asset, trackId: trackId, startFrame: entry.startFrame, durationFrames: entry.durationFrames))
        }

        // All-or-none for trackIndex: a new track at index 0 would shift any explicit indices.
        let omittedCount = specs.filter { $0.trackId == nil }.count
        guard omittedCount == 0 || omittedCount == specs.count else {
            throw ToolError("Mixed trackIndex: \(omittedCount) of \(specs.count) entries omitted trackIndex. Either set it on every entry or omit it on every entry (to auto-create shared tracks).")
        }

        let actionName = specs.count == 1 ? "Add Clip (Agent)" : "Add Clips (Agent)"
        let (createdTracks, summaries) = try withUndoGroup(editor, actionName: actionName) { () -> ([String], [String]) in
            var createdTracks: [String] = []
            // IDs already attributed to the response so the post-batch side-effect
            // sweep doesn't double-count them.
            var reportedTrackIds: Set<String> = []
            let reportTrack: (Int) -> Void = { idx in
                let t = editor.timeline.tracks[idx]
                createdTracks.append("track \(idx) ('\(editor.timelineTrackDisplayLabel(at: idx))', \(t.type.rawValue))")
                reportedTrackIds.insert(t.id)
            }
            if omittedCount == specs.count {
                let needsVideo = specs.contains { $0.asset.type != .audio }
                let needsAudio = specs.contains { $0.asset.type == .audio }
                var videoTrackId: String? = nil
                var audioTrackId: String? = nil
                if needsVideo {
                    let idx = editor.insertTrack(at: 0, type: .video)
                    videoTrackId = editor.timeline.tracks[idx].id
                    reportTrack(idx)
                }
                if needsAudio {
                    let idx = editor.insertTrack(at: 0, type: .audio)
                    audioTrackId = editor.timeline.tracks[idx].id
                    reportTrack(idx)
                }
                for i in specs.indices {
                    specs[i].trackId = (specs[i].asset.type == .audio) ? audioTrackId : videoTrackId
                }
            }

            var allAdded: [String] = []
            var summaries: [String] = []
            let tracksBefore = Set(editor.timeline.tracks.map(\.id))
            let nonEmptyBefore = Set(editor.timeline.tracks.filter { !$0.clips.isEmpty }.map(\.id))

            let orderedIndices = specs.indices.sorted {
                let aAudio = specs[$0].asset.type == .audio ? 0 : 1
                let bAudio = specs[$1].asset.type == .audio ? 0 : 1
                if aAudio != bAudio { return aAudio < bAudio }
                return (specs[$0].trackId!, specs[$0].startFrame) < (specs[$1].trackId!, specs[$1].startFrame)
            }
            for i in orderedIndices {
                let spec = specs[i]
                let trackId = spec.trackId!
                guard let trackIdx = editor.timeline.tracks.firstIndex(where: { $0.id == trackId }) else {
                    throw ToolError("entries[\(i)]: destination track no longer exists")
                }
                editor.clearRegion(trackIndex: trackIdx, start: spec.startFrame, end: spec.startFrame + spec.durationFrames, prune: false)
                let ids = editor.placeClip(
                    asset: spec.asset, trackIndex: trackIdx,
                    startFrame: spec.startFrame, durationFrames: spec.durationFrames
                )
                guard let primary = ids.first else {
                    throw ToolError("entries[\(i)]: failed to place clip on track \(trackIdx) at frame \(spec.startFrame)")
                }
                allAdded.append(contentsOf: ids)
                let pairedNote = ids.count > 1 ? " (+linked audio \(ids[1]))" : ""
                summaries.append("\(primary) on track \(trackIdx) @ \(spec.startFrame) for \(spec.durationFrames)\(pairedNote)")
            }

            for track in editor.timeline.tracks where track.clips.isEmpty && nonEmptyBefore.contains(track.id) {
                editor.removeTrack(id: track.id)
            }

            for (idx, track) in editor.timeline.tracks.enumerated()
                where !tracksBefore.contains(track.id) && !reportedTrackIds.contains(track.id) {
                reportTrack(idx)
            }
            let addedIds = allAdded
            editor.undoManager?.registerUndo(withTarget: editor) { vm in
                vm.removeClips(ids: Set(addedIds))
            }
            return (createdTracks, summaries)
        }
        editor.notifyTimelineChanged()

        let prefix = createdTracks.isEmpty ? "" : "Created \(createdTracks.joined(separator: ", ")). "
        return .ok("\(prefix)Added \(specs.count) clip\(specs.count == 1 ? "" : "s"): \(summaries.joined(separator: "; "))")
    }

    // MARK: remove_clips

    func removeClips(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["clipIds"], path: "remove_clips")
        let clipIds = args.stringArray("clipIds")
        guard !clipIds.isEmpty else { throw ToolError("Missing or empty 'clipIds' array") }
        for id in clipIds {
            guard editor.findClip(id: id) != nil else { throw ToolError("Clip not found: \(id)") }
        }
        let expanded = editor.expandToLinkGroup(Set(clipIds))
        let tracksBefore = Set(editor.timeline.tracks.map(\.id))
        editor.removeClips(ids: expanded)
        let prunedCount = tracksBefore.subtracting(editor.timeline.tracks.map(\.id)).count

        let extras = expanded.count - clipIds.count
        let linkedNote = extras > 0 ? " (+\(extras) linked)" : ""
        let pruneNote = prunedCount > 0
            ? ". Pruned \(prunedCount) empty track\(prunedCount == 1 ? "" : "s") — track indices have shifted; re-read with get_timeline before next index-based call"
            : ""
        return .ok("Removed \(expanded.count) clip\(expanded.count == 1 ? "" : "s")\(linkedNote)\(pruneNote): \(clipIds.joined(separator: ", "))")
    }

    // MARK: move_clips

    func moveClips(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: MoveClipsInput = try decodeToolArgs(args, path: "move_clips")
        guard !input.moves.isEmpty else { throw ToolError("Missing or empty 'moves' array") }
        if let raws = args["moves"] as? [Any] {
            for (idx, raw) in raws.enumerated() {
                if let d = raw as? [String: Any] {
                    try validateUnknownKeys(d, allowed: MoveClipsInput.Move.allowedKeys, path: "moves[\(idx)]")
                }
            }
        }

        var parsed: [ParsedMove] = []
        parsed.reserveCapacity(input.moves.count)
        for (idx, m) in input.moves.enumerated() {
            let path = "moves[\(idx)]"
            guard m.toTrack != nil || m.toFrame != nil else {
                throw ToolError("\(path): at least one of 'toTrack' or 'toFrame' is required")
            }
            guard let loc = editor.findClip(id: m.clipId) else {
                throw ToolError("\(path): clip not found: \(m.clipId)")
            }
            var destTrackId: String? = nil
            if let ti = m.toTrack {
                guard editor.timeline.tracks.indices.contains(ti) else {
                    throw ToolError("\(path): toTrack \(ti) out of range (0..\(editor.timeline.tracks.count - 1))")
                }
                let srcType = editor.timeline.tracks[loc.trackIndex].type
                let destType = editor.timeline.tracks[ti].type
                guard destType.isCompatible(with: srcType) else {
                    throw ToolError("\(path): toTrack \(ti) (\(destType.rawValue)) is incompatible with clip's \(srcType.rawValue) source track")
                }
                destTrackId = editor.timeline.tracks[ti].id
            }
            if let f = m.toFrame, f < 0 {
                throw ToolError("\(path): toFrame must be >= 0 (got \(f))")
            }
            parsed.append(ParsedMove(clipId: m.clipId, destTrackId: destTrackId, toFrame: m.toFrame))
        }

        // Expand to linked partners via the shared model helper.
        var seen: Set<String> = Set(parsed.map(\.clipId))
        var allMoves = parsed
        for p in parsed {
            guard let toFrame = p.toFrame else { continue }
            for pm in editor.partnerMoves(forMoveOf: p.clipId, toFrame: toFrame) where !seen.contains(pm.clipId) {
                allMoves.append(ParsedMove(clipId: pm.clipId, destTrackId: nil, toFrame: pm.toFrame))
                seen.insert(pm.clipId)
            }
        }
        let linkedCount = allMoves.count - parsed.count

        let moveActionName = parsed.count == 1 ? "Move Clip (Agent)" : "Move Clips (Agent)"
        withUndoGroup(editor, actionName: moveActionName) {
            var moves: [(clipId: String, toTrack: Int, toFrame: Int)] = []
            for m in allMoves {
                guard let loc = editor.findClip(id: m.clipId) else { continue }
                let currentTrackIdx = loc.trackIndex
                let currentFrame = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].startFrame
                let toTrack: Int
                if let destId = m.destTrackId,
                   let idx = editor.timeline.tracks.firstIndex(where: { $0.id == destId }) {
                    toTrack = idx
                } else {
                    toTrack = currentTrackIdx
                }
                moves.append((clipId: m.clipId, toTrack: toTrack, toFrame: m.toFrame ?? currentFrame))
            }
            if !moves.isEmpty { editor.moveClips(moves) }
        }

        let linkedNote = linkedCount > 0 ? " (+\(linkedCount) linked)" : ""
        let summary = parsed.map { p -> String in
            var bits: [String] = []
            if p.destTrackId != nil { bits.append("track") }
            if p.toFrame != nil { bits.append("frame") }
            return "\(p.clipId): \(bits.joined(separator: ", "))"
        }.joined(separator: "; ")
        return .ok("Moved \(parsed.count) clip\(parsed.count == 1 ? "" : "s")\(linkedNote): \(summary)")
    }

    // MARK: set_clip_properties

    private static let textOnlyKeys: Set<String> = ["content", "fontName", "fontSize", "color", "alignment"]

    func setClipProperties(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: SetClipPropertiesInput = try decodeToolArgs(args, path: "set_clip_properties")
        guard !input.clipIds.isEmpty else { throw ToolError("Missing or empty 'clipIds' array") }
        guard input.hasAnyProperty else {
            throw ToolError("set_clip_properties needs at least one property to apply")
        }
        if let df = input.durationFrames, df < 1 {
            throw ToolError("durationFrames must be >= 1 (got \(df))")
        }
        let color = try parseColorHex(input.color, path: "set_clip_properties")
        let alignment = try parseAlignment(input.alignment, path: "set_clip_properties")

        // Resolve clipIds + collect types so we can reject text-only fields on non-text clips.
        var clipTypes: [String: ClipType] = [:]
        for id in input.clipIds {
            guard let loc = editor.findClip(id: id) else { throw ToolError("Clip not found: \(id)") }
            clipTypes[id] = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].mediaType
        }
        let textOnlyUsed = [
            input.content   != nil ? "content"   : nil,
            input.fontName  != nil ? "fontName"  : nil,
            input.fontSize  != nil ? "fontSize"  : nil,
            input.color     != nil ? "color"     : nil,
            input.alignment != nil ? "alignment" : nil,
        ].compactMap { $0 }
        if !textOnlyUsed.isEmpty {
            let nonText = clipTypes.filter { $0.value != .text }.map { $0.key }.sorted()
            if !nonText.isEmpty {
                throw ToolError("text-only fields '\(textOnlyUsed.joined(separator: "', '"))' rejected on non-text clips: \(nonText.joined(separator: ", "))")
            }
        }

        // Expand timing fields to linked partners via the shared model helper.
        // Partners drop trim/speed when they're text — handled per-partner below.
        let propagatesTiming = input.durationFrames != nil || input.trimStartFrame != nil
            || input.trimEndFrame != nil || input.speed != nil
        let partners: Set<String> = propagatesTiming
            ? editor.timingPropagationPartners(of: Set(input.clipIds))
            : []

        let setActionName = input.clipIds.count == 1 ? "Set Clip Property (Agent)" : "Set Clip Properties (Agent)"
        let summaries: [String] = withUndoGroup(editor, actionName: setActionName) {
            var summaries: [String] = []
            for id in input.clipIds {
                let isText = clipTypes[id] == .text
                let changed = Self.applyPropertyChanges(
                    durationFrames: input.durationFrames,
                    trimStartFrame: input.trimStartFrame,
                    trimEndFrame: input.trimEndFrame,
                    speed: input.speed,
                    volume: input.volume,
                    opacity: input.opacity,
                    transform: input.transform,
                    content: isText ? input.content : nil,
                    fontName: isText ? input.fontName : nil,
                    fontSize: isText ? input.fontSize : nil,
                    color: isText ? color : nil,
                    alignment: isText ? alignment : nil,
                    clipId: id,
                    editor: editor
                )
                // Match the inspector: refit bbox after content/font change when caller didn't set a box.
                if isText && input.transform == nil && (input.content != nil || input.fontName != nil || input.fontSize != nil) {
                    editor.fitTextClipToContent(clipId: id)
                }
                summaries.append("\(id)\(changed.isEmpty ? " (no-op)" : ": \(changed.joined(separator: ", "))")")
            }
            for partnerId in partners {
                guard let pLoc = editor.findClip(id: partnerId) else { continue }
                let partnerIsText = editor.timeline.tracks[pLoc.trackIndex].clips[pLoc.clipIndex].mediaType == .text
                _ = Self.applyPropertyChanges(
                    durationFrames: input.durationFrames,
                    trimStartFrame: partnerIsText ? nil : input.trimStartFrame,
                    trimEndFrame:   partnerIsText ? nil : input.trimEndFrame,
                    speed:          partnerIsText ? nil : input.speed,
                    volume: nil, opacity: nil, transform: nil,
                    content: nil, fontName: nil, fontSize: nil, color: nil, alignment: nil,
                    clipId: partnerId,
                    editor: editor
                )
            }
            return summaries
        }

        let linkedNote = partners.isEmpty ? "" : " (+\(partners.count) linked)"
        return .ok("Updated \(input.clipIds.count) clip\(input.clipIds.count == 1 ? "" : "s")\(linkedNote): \(summaries.joined(separator: "; "))")
    }

    fileprivate static func applyPropertyChanges(
        durationFrames: Int?,
        trimStartFrame: Int?,
        trimEndFrame: Int?,
        speed: Double?,
        volume: Double?,
        opacity: Double?,
        transform: ParsedTransform?,
        content: String?,
        fontName: String?,
        fontSize: Double?,
        color: TextStyle.RGBA?,
        alignment: TextStyle.Alignment?,
        clipId: String,
        editor: EditorViewModel
    ) -> [String] {
        var changed: [String] = []
        editor.commitClipProperty(clipId: clipId) { clip in
            if let v = durationFrames {
                clip.durationFrames = v
                clip.clampKeyframesToDuration()
                clip.clampFadesToDuration()
                changed.append("durationFrames")
            }
            if let v = trimStartFrame { clip.trimStartFrame = v; changed.append("trimStartFrame") }
            if let v = trimEndFrame   { clip.trimEndFrame   = v; changed.append("trimEndFrame") }
            if let v = speed {
                if durationFrames == nil, v > 0 {
                    let sourceConsumed = Double(clip.durationFrames) * clip.speed
                    clip.durationFrames = max(1, Int((sourceConsumed / v).rounded()))
                    clip.clampKeyframesToDuration()
                    clip.clampFadesToDuration()
                    changed.append("durationFrames")
                }
                clip.speed = v
                changed.append("speed")
            }
            // Setting a scalar clears any existing keyframe track on the same property.
            if let v = volume         { clip.volume  = v; clip.volumeTrack  = nil; changed.append("volume") }
            if let v = opacity        { clip.opacity = v; clip.opacityTrack = nil; changed.append("opacity") }
            if let t = transform {
                let cur = clip.transform
                var next = Transform(
                    center: (t.centerX ?? cur.center.x, t.centerY ?? cur.center.y),
                    width: t.width ?? cur.width,
                    height: t.height ?? cur.height
                )
                next.flipHorizontal = t.flipHorizontal ?? cur.flipHorizontal
                next.flipVertical = t.flipVertical ?? cur.flipVertical
                clip.transform = next
                changed.append("transform")
            }
            if content != nil || fontName != nil || fontSize != nil || color != nil || alignment != nil {
                if let c = content { clip.textContent = c; changed.append("content") }
                var style = clip.textStyle ?? TextStyle()
                if let f = fontName  { style.fontName = f; changed.append("fontName") }
                if let s = fontSize  { style.fontSize = s; changed.append("fontSize") }
                if let c = color     { style.color = c; changed.append("color") }
                if let a = alignment { style.alignment = a; changed.append("alignment") }
                clip.textStyle = style
            }
        }
        return changed
    }

    // MARK: set_keyframes

    private static let keyframePropertyNames: Set<String> = ["volume", "opacity", "rotation", "position", "scale", "crop"]

    func setKeyframes(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: SetKeyframesInput = try decodeToolArgs(args, path: "set_keyframes")
        guard let rows = args["keyframes"] as? [Any] else {
            throw ToolError("Missing required field 'keyframes' (must be an array)")
        }
        guard Self.keyframePropertyNames.contains(input.property) else {
            throw ToolError("Unknown property '\(input.property)'. Expected one of: \(Self.keyframePropertyNames.sorted().joined(separator: ", "))")
        }
        guard editor.findClip(id: input.clipId) != nil else {
            throw ToolError("Clip not found: \(input.clipId)")
        }

        try withUndoGroup(editor, actionName: "Set Keyframes (Agent)") {
            switch input.property {
            case "volume":
                let kfs = try Self.parseScalarKeyframes(rows, path: "keyframes")
                editor.commitClipProperty(clipId: input.clipId) { $0.volumeTrack = kfs.keyframes.isEmpty ? nil : kfs }
            case "opacity":
                let kfs = try Self.parseScalarKeyframes(rows, path: "keyframes")
                editor.commitClipProperty(clipId: input.clipId) { $0.opacityTrack = kfs.keyframes.isEmpty ? nil : kfs }
            case "rotation":
                let kfs = try Self.parseScalarKeyframes(rows, path: "keyframes")
                editor.commitClipProperty(clipId: input.clipId) { $0.rotationTrack = kfs.keyframes.isEmpty ? nil : kfs }
            case "position":
                let kfs = try Self.parsePairKeyframes(rows, path: "keyframes")
                editor.commitClipProperty(clipId: input.clipId) { $0.positionTrack = kfs.keyframes.isEmpty ? nil : kfs }
            case "scale":
                let kfs = try Self.parsePairKeyframes(rows, path: "keyframes")
                editor.commitClipProperty(clipId: input.clipId) { $0.scaleTrack = kfs.keyframes.isEmpty ? nil : kfs }
            case "crop":
                let kfs = try Self.parseCropKeyframes(rows, path: "keyframes")
                editor.commitClipProperty(clipId: input.clipId) { $0.cropTrack = kfs.keyframes.isEmpty ? nil : kfs }
            default:
                break  // unreachable: validated above
            }
        }

        let action = rows.isEmpty ? "cleared" : "set \(rows.count)"
        return .ok("\(action) keyframes on \(input.property) for \(input.clipId)")
    }

    // MARK: split_clip

    func splitClip(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let clipId = try args.requireString("clipId")
        let atFrame = try args.requireInt("atFrame")
        guard let loc = editor.findClip(id: clipId) else { throw ToolError("Clip not found: \(clipId)") }
        let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard atFrame > clip.startFrame && atFrame < clip.endFrame else {
            throw ToolError("Frame \(atFrame) is outside clip range (\(clip.startFrame)..\(clip.endFrame))")
        }
        let rightIds = editor.splitClip(clipId: clipId, atFrame: atFrame)
        let rightEndFrame = clip.endFrame
        let leftSummary = "\(clipId) (frames \(clip.startFrame)..\(atFrame))"
        let rightList = rightIds
            .map { "\($0) (frames \(atFrame)..\(rightEndFrame))" }
            .joined(separator: ", ")
        let rightNote = rightIds.isEmpty ? "" : " → new right clip(s): \(rightList)"
        return .ok("Split clip \(clipId) at frame \(atFrame). Left: \(leftSummary)\(rightNote)")
    }

    // MARK: ripple_delete_ranges

    func rippleDeleteRanges(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: RippleDeleteRangesInput = try decodeToolArgs(args, path: "ripple_delete_ranges")
        guard !input.ranges.isEmpty else { throw ToolError("Missing or empty 'ranges' array") }
        let units = input.units ?? "frames"
        guard units == "seconds" || units == "frames" else {
            throw ToolError("units must be 'seconds' or 'frames' (got '\(units)')")
        }
        guard let loc = editor.findClip(id: input.clipId) else {
            throw ToolError("Clip not found: \(input.clipId)")
        }
        let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        let fps = editor.timeline.fps

        // 'frames' are already project frames (inspect_media with a clipId emits these).
        // 'seconds' are source-media seconds → map through the clip's placement, trim, speed.
        func toFrame(_ v: Double) -> Double {
            units == "frames"
                ? v
                : Double(clip.startFrame) + (v * Double(fps) - Double(clip.trimStartFrame)) / max(clip.speed, 0.0001)
        }

        var frameRanges: [FrameRange] = []
        var dropped = 0
        for (i, r) in input.ranges.enumerated() {
            guard r.count == 2 else {
                throw ToolError("ranges[\(i)]: expected [start, end] (got \(r.count) element\(r.count == 1 ? "" : "s"))")
            }
            guard r[1] > r[0] else {
                throw ToolError("ranges[\(i)]: end (\(r[1])) must be greater than start (\(r[0]))")
            }
            let s = max(clip.startFrame, min(clip.endFrame, Int(toFrame(r[0]).rounded())))
            let e = max(clip.startFrame, min(clip.endFrame, Int(toFrame(r[1]).rounded())))
            if e > s { frameRanges.append(FrameRange(start: s, end: e)) } else { dropped += 1 }
        }
        guard !frameRanges.isEmpty else {
            throw ToolError("No ranges fall within clip \(input.clipId) (frames \(clip.startFrame)..\(clip.endFrame)). In '\(units)' units, ranges must overlap the clip's visible span.")
        }

        switch editor.rippleDeleteRanges(anchorClipId: input.clipId, ranges: frameRanges) {
        case .refused(let reason):
            throw ToolError(reason)
        case .ok(let report):
            var payload: [String: Any] = [
                "removedFrames": report.removedFrames,
                "clearedTracks": report.clearedTracks,
                "shiftedClips": report.shiftedClips,
                "anchorTrackIndex": report.anchorTrackIndex,
                "resultingClips": report.resultingFragments.map {
                    ["clipId": $0.clipId, "startFrame": $0.startFrame, "durationFrames": $0.durationFrames]
                },
            ]
            if !report.removedClipIds.isEmpty { payload["removedClipIds"] = report.removedClipIds }
            if dropped > 0 { payload["rangesIgnored"] = dropped }
            guard let json = Self.jsonString(payload) else { throw ToolError("Failed to encode result") }
            return .ok(json)
        }
    }

    // MARK: - Keyframe row parsing (shared by set_keyframes)

    /// Parse `[[frame, value0, value1, ..., interp?], ...]` into a keyframe track.
    private static func parseKeyframes<V>(
        _ rows: [Any], path: String, fieldNames: [String], build: ([Double]) -> V
    ) throws -> KeyframeTrack<V> {
        let arity = fieldNames.count
        let labels = fieldNames.joined(separator: ", ")
        let minLen = arity + 1
        let maxLen = arity + 2

        var out: [Keyframe<V>] = []
        for (i, raw) in rows.enumerated() {
            guard let row = raw as? [Any] else {
                throw ToolError("\(path)[\(i)]: expected array [frame, \(labels), interp?]")
            }
            guard row.count == minLen || row.count == maxLen else {
                throw ToolError("\(path)[\(i)]: expected [frame, \(labels)] or [frame, \(labels), interp] (got \(row.count) elements)")
            }
            let frame = try kfInt(row[0], at: "\(path)[\(i)][0] (frame)")
            let values = try (0..<arity).map { k in
                try kfDouble(row[k + 1], at: "\(path)[\(i)][\(k + 1)] (\(fieldNames[k]))")
            }
            let interp = try kfInterp(row.count > minLen ? row[minLen] : nil, at: "\(path)[\(i)][\(minLen)] (interp)")
            out.append(Keyframe(frame: frame, value: build(values), interpolationOut: interp))
        }
        return KeyframeTrack(keyframes: sortAndDedupe(out))
    }

    fileprivate static func parseScalarKeyframes(_ rows: [Any], path: String) throws -> KeyframeTrack<Double> {
        try parseKeyframes(rows, path: path, fieldNames: ["value"]) { $0[0] }
    }

    fileprivate static func parsePairKeyframes(_ rows: [Any], path: String) throws -> KeyframeTrack<AnimPair> {
        try parseKeyframes(rows, path: path, fieldNames: ["a", "b"]) { AnimPair(a: $0[0], b: $0[1]) }
    }

    fileprivate static func parseCropKeyframes(_ rows: [Any], path: String) throws -> KeyframeTrack<Crop> {
        try parseKeyframes(rows, path: path, fieldNames: ["top", "right", "bottom", "left"]) {
            Crop(left: $0[3], top: $0[0], right: $0[1], bottom: $0[2])
        }
    }

    private static func sortAndDedupe<V>(_ kfs: [Keyframe<V>]) -> [Keyframe<V>] {
        let sorted = kfs.sorted { $0.frame < $1.frame }
        var out: [Keyframe<V>] = []
        out.reserveCapacity(sorted.count)
        for kf in sorted {
            if out.last?.frame == kf.frame { out[out.count - 1] = kf } else { out.append(kf) }
        }
        return out
    }

    private static func kfInt(_ raw: Any, at path: String) throws -> Int {
        if let v = raw as? Int { return v }
        if let v = raw as? Double { return Int(v) }
        if let v = raw as? NSNumber { return v.intValue }
        throw ToolError("\(path): expected integer")
    }

    private static func kfDouble(_ raw: Any, at path: String) throws -> Double {
        let v: Double
        if let d = raw as? Double { v = d }
        else if let i = raw as? Int { v = Double(i) }
        else if let n = raw as? NSNumber { v = n.doubleValue }
        else { throw ToolError("\(path): expected number") }
        guard v.isFinite else {
            throw ToolError("\(path): value must be finite (got \(v))")
        }
        return v
    }

    private static func kfInterp(_ raw: Any?, at path: String) throws -> Interpolation {
        guard let raw else { return .smooth }
        guard let s = raw as? String, let i = Interpolation(rawValue: s) else {
            throw ToolError("\(path): expected one of 'linear', 'hold', 'smooth' (got \(raw))")
        }
        return i
    }

    private static let removeTracksAllowedKeys: Set<String> = ["trackIndexes"]

    func removeTracks(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.removeTracksAllowedKeys, path: "remove_tracks")
        guard let raw = args["trackIndexes"] as? [Any], !raw.isEmpty else {
            throw ToolError("remove_tracks: trackIndexes must be a non-empty array of integers")
        }
        var removed: [[String: Any]] = []
        var ids: [String] = []
        var seen = Set<Int>()
        for entry in raw {
            guard let i = (entry as? Int) ?? (entry as? NSNumber)?.intValue else {
                throw ToolError("remove_tracks: trackIndexes must be integers (got \(entry))")
            }
            guard seen.insert(i).inserted else { continue }
            guard editor.timeline.tracks.indices.contains(i) else {
                throw ToolError("remove_tracks: track index \(i) out of range (timeline has \(editor.timeline.tracks.count) tracks)")
            }
            let track = editor.timeline.tracks[i]
            ids.append(track.id)
            removed.append([
                "trackIndex": i,
                "label": editor.timelineTrackDisplayLabel(at: i),
                "clipCount": track.clips.count,
            ])
        }
        editor.removeTracks(ids: ids)
        guard let json = Self.jsonString(["removedTracks": removed]) else {
            throw ToolError("Failed to encode result")
        }
        return .ok(json)
    }
}
