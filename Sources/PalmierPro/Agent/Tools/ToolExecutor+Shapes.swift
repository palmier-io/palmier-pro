import Foundation

extension ToolExecutor {
    private static let addShapesEntryKeys: Set<String> = [
        "kind", "trackIndex", "startFrame", "durationFrames",
        "transform", "endpoints", "style",
        "enterAnim", "enterDurationFrames",
        "exitAnim", "exitDurationFrames",
        "loopAnim",
    ]
    private static let addShapesAllowedKeys: Set<String> = ["entries"]
    private static let shapeStyleAllowedKeys: Set<String> = [
        "strokeColor", "strokeWidth", "fillColor",
        "cornerRadius", "arrowheadStyle", "arrowheadSize", "dash",
    ]
    private static let shapeTransformAllowedKeys: Set<String> = ["centerX", "centerY", "width", "height"]
    private static let shapeEndpointsAllowedKeys: Set<String> = ["fromX", "fromY", "toX", "toY", "controlX", "controlY"]

    private struct ParsedShapeEntry {
        let trackIndex: Int?
        let startFrame: Int
        let durationFrames: Int
        let style: ShapeStyle
        let transform: Transform?
        let enterAnim: AnimationPreset?
        let enterDurationFrames: Int?
        let exitAnim: AnimationPreset?
        let exitDurationFrames: Int?
        let loopAnim: AnimationPreset?
    }

    func addShapes(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.addShapesAllowedKeys, path: "add_shapes")
        guard let rawEntries = args["entries"] as? [Any], !rawEntries.isEmpty else {
            throw ToolError("Missing or empty 'entries' array")
        }

        var parsed: [ParsedShapeEntry] = []
        parsed.reserveCapacity(rawEntries.count)
        for (idx, raw) in rawEntries.enumerated() {
            let path = "entries[\(idx)]"
            guard let entry = raw as? [String: Any] else {
                throw ToolError("\(path) must be an object")
            }
            try validateUnknownKeys(entry, allowed: Self.addShapesEntryKeys, path: path)

            guard let kindStr = entry.string("kind"), let kind = ShapeStyle.Kind(rawValue: kindStr) else {
                throw ToolError("\(path): 'kind' is required, one of \(ShapeStyle.Kind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            let startFrame = try entry.requireInt("startFrame")
            let durationFrames = try entry.requireInt("durationFrames")
            guard startFrame >= 0 else { throw ToolError("\(path): startFrame must be >= 0 (got \(startFrame))") }
            guard durationFrames >= 1 else { throw ToolError("\(path): durationFrames must be >= 1 (got \(durationFrames))") }

            let trackIndex = entry.int("trackIndex")
            if let ti = trackIndex {
                guard editor.timeline.tracks.indices.contains(ti) else {
                    throw ToolError("\(path): track index \(ti) out of range (0..\(editor.timeline.tracks.count - 1))")
                }
                guard ClipType.shape.isCompatible(with: editor.timeline.tracks[ti].type) else {
                    throw ToolError("\(path): track \(ti) is an audio track; shapes require a visual track")
                }
            }

            var style = ShapeStyle()
            style.kind = kind

            if let styleDict = entry["style"] as? [String: Any] {
                try validateUnknownKeys(styleDict, allowed: Self.shapeStyleAllowedKeys, path: "\(path).style")
                if let c = try parseColorHex(styleDict.string("strokeColor"), path: "\(path).style.strokeColor") {
                    style.stroke.color = c
                    style.stroke.enabled = true
                }
                if let w = styleDict.double("strokeWidth") {
                    guard w >= 0 else { throw ToolError("\(path).style.strokeWidth must be >= 0") }
                    style.stroke.width = w
                    style.stroke.enabled = w > 0
                }
                if let f = try parseColorHex(styleDict.string("fillColor"), path: "\(path).style.fillColor") {
                    style.fill.color = f
                    style.fill.enabled = true
                }
                if let r = styleDict.double("cornerRadius") {
                    guard r >= 0 && r <= 0.5 else { throw ToolError("\(path).style.cornerRadius must be 0..0.5") }
                    style.cornerRadius = r
                }
                if let ahStr = styleDict.string("arrowheadStyle") {
                    guard let ah = ShapeStyle.Arrowhead.Style(rawValue: ahStr) else {
                        throw ToolError("\(path).style.arrowheadStyle: expected 'triangle', 'open', or 'none' (got '\(ahStr)')")
                    }
                    style.arrowhead.style = ah
                }
                if let s = styleDict.double("arrowheadSize") {
                    guard s >= 0 else { throw ToolError("\(path).style.arrowheadSize must be >= 0") }
                    style.arrowhead.size = s
                }
                if let dashes = styleDict["dash"] as? [Any] {
                    var out: [Double] = []
                    out.reserveCapacity(dashes.count)
                    for (di, raw) in dashes.enumerated() {
                        guard let v = (raw as? Double) ?? (raw as? Int).map(Double.init) ?? (raw as? NSNumber)?.doubleValue, v.isFinite, v > 0 else {
                            throw ToolError("\(path).style.dash[\(di)] must be a positive number")
                        }
                        out.append(v)
                    }
                    style.stroke.dash = out
                }
            }

            if let endpointsDict = entry["endpoints"] as? [String: Any] {
                try validateUnknownKeys(endpointsDict, allowed: Self.shapeEndpointsAllowedKeys, path: "\(path).endpoints")
                guard let fx = endpointsDict.double("fromX"), let fy = endpointsDict.double("fromY"),
                      let tx = endpointsDict.double("toX"), let ty = endpointsDict.double("toY") else {
                    throw ToolError("\(path).endpoints requires fromX, fromY, toX, toY")
                }
                style.endpoints = ShapeStyle.Endpoints(
                    fromX: fx, fromY: fy, toX: tx, toY: ty,
                    controlX: endpointsDict.double("controlX"),
                    controlY: endpointsDict.double("controlY")
                )
            }
            if (kind == .arrow || kind == .line) && style.endpoints == nil {
                throw ToolError("\(path): kind '\(kindStr)' requires 'endpoints' { fromX, fromY, toX, toY }")
            }

            var transform: Transform? = nil
            if let tDict = entry["transform"] as? [String: Any] {
                try validateUnknownKeys(tDict, allowed: Self.shapeTransformAllowedKeys, path: "\(path).transform")
                guard let cx = tDict.double("centerX"), let cy = tDict.double("centerY"),
                      let w = tDict.double("width"), let h = tDict.double("height") else {
                    throw ToolError("\(path).transform must contain centerX, centerY, width, height")
                }
                transform = Transform(center: (cx, cy), width: w, height: h)
            }

            let enterAnim = try parsePreset(entry.string("enterAnim"), kind: .enter, path: "\(path).enterAnim")
            let exitAnim = try parsePreset(entry.string("exitAnim"), kind: .exit, path: "\(path).exitAnim")
            let loopAnim = try parsePreset(entry.string("loopAnim"), kind: .loop, path: "\(path).loopAnim")

            parsed.append(.init(
                trackIndex: trackIndex,
                startFrame: startFrame,
                durationFrames: durationFrames,
                style: style,
                transform: transform,
                enterAnim: enterAnim,
                enterDurationFrames: entry.int("enterDurationFrames"),
                exitAnim: exitAnim,
                exitDurationFrames: entry.int("exitDurationFrames"),
                loopAnim: loopAnim
            ))
        }

        let omittedCount = parsed.filter { $0.trackIndex == nil }.count
        guard omittedCount == 0 || omittedCount == parsed.count else {
            throw ToolError("Mixed trackIndex: \(omittedCount) of \(parsed.count) entries omitted trackIndex. Either set it on every entry or omit it on every entry (to auto-create a shared new track).")
        }

        let actionName = parsed.count == 1 ? "Add Shape (Agent)" : "Add Shapes (Agent)"
        let (ids, createdTrackInfo, summaries) = try withUndoGroup(editor, actionName: actionName) {
            () -> ([String], String?, [String]) in
            var createdTrackInfo: String? = nil
            var createdTrackId: String? = nil
            let resolvedTrackId: String?
            if omittedCount == parsed.count {
                let newIdx = editor.insertTrack(at: 0, type: .video)
                createdTrackInfo = "track \(newIdx) ('\(editor.timelineTrackDisplayLabel(at: newIdx))')"
                createdTrackId = editor.timeline.tracks.indices.contains(newIdx)
                    ? editor.timeline.tracks[newIdx].id
                    : nil
                resolvedTrackId = createdTrackId
            } else {
                resolvedTrackId = nil
            }

            var specs: [EditorViewModel.ShapeClipSpec] = []
            specs.reserveCapacity(parsed.count)
            for p in parsed {
                let trackIdx: Int
                if let resolvedTrackId,
                   let i = editor.timeline.tracks.firstIndex(where: { $0.id == resolvedTrackId }) {
                    trackIdx = i
                } else if let explicit = p.trackIndex {
                    trackIdx = explicit
                } else {
                    continue
                }
                specs.append(.init(
                    trackIndex: trackIdx,
                    startFrame: p.startFrame,
                    durationFrames: p.durationFrames,
                    style: p.style,
                    transform: p.transform
                ))
            }

            let placedIds = editor.placeShapeClips(specs)
            guard !placedIds.isEmpty else {
                if let tid = createdTrackId { editor.removeTrack(id: tid) }
                throw ToolError("Failed to place any shape clips")
            }

            // Apply enter / exit / loop animations to each placed clip.
            var summaries: [String] = []
            summaries.reserveCapacity(placedIds.count)
            for (i, clipId) in placedIds.enumerated() {
                let p = parsed[i]
                var animNotes: [String] = []
                applyOptionalAnimation(p.enterAnim, windowFrames: p.enterDurationFrames, clipId: clipId, editor: editor, notes: &animNotes)
                applyOptionalAnimation(p.exitAnim, windowFrames: p.exitDurationFrames, clipId: clipId, editor: editor, notes: &animNotes)
                applyOptionalAnimation(p.loopAnim, windowFrames: nil, clipId: clipId, editor: editor, notes: &animNotes)

                let trackIdx = editor.findClip(id: clipId)?.trackIndex ?? -1
                let extras = animNotes.isEmpty ? "" : " [\(animNotes.joined(separator: ", "))]"
                summaries.append("\(clipId) (\(p.style.kind.rawValue)) on track \(trackIdx) @ \(p.startFrame) for \(p.durationFrames)\(extras)")
            }

            editor.undoManager?.registerUndo(withTarget: editor) { vm in
                vm.removeClips(ids: Set(placedIds))
            }
            return (placedIds, createdTrackInfo, summaries)
        }
        // Shapes render via the CAShapeLayer overlay, not the AVFoundation composition.
        // Skip the composition rebuild — same pattern text clips use to dodge an
        // AVAsset load when only overlay state changed.
        editor.videoEngine?.syncShapeLayers()

        let prefix = createdTrackInfo.map { "Created \($0). " } ?? ""
        return .ok("\(prefix)Added \(ids.count) shape clip\(ids.count == 1 ? "" : "s"): \(summaries.joined(separator: "; "))")
    }

    func applyAnimation(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["clipId", "preset", "windowFrames", "intensity"], path: "apply_animation")
        let clipId = try args.requireString("clipId")
        let presetStr = try args.requireString("preset")
        guard let preset = AnimationPreset(rawValue: presetStr) else {
            throw ToolError("apply_animation: unknown preset '\(presetStr)'. Available: \(AnimationPreset.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let windowFrames = args.int("windowFrames")
        if let w = windowFrames, w < 1 {
            throw ToolError("apply_animation: windowFrames must be >= 1 (got \(w))")
        }
        let intensity: AnimationIntensity
        if let raw = args.string("intensity") {
            guard let parsed = AnimationIntensity(rawValue: raw) else {
                throw ToolError("apply_animation: intensity must be 'subtle', 'medium', or 'strong' (got '\(raw)')")
            }
            intensity = parsed
        } else {
            intensity = .medium
        }

        guard let loc = editor.findClip(id: clipId) else { throw ToolError("Clip not found: \(clipId)") }
        let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]

        try withUndoGroup(editor, actionName: "Apply Animation (Agent)") {
            applyPreset(preset, windowFrames: windowFrames, intensity: intensity, clipId: clipId, restingTransform: clip.transform, clipDurationFrames: clip.durationFrames, editor: editor)
        }
        // Skip composition rebuild for shape-only animations — same reason as add_shapes.
        if clip.mediaType == .shape {
            editor.videoEngine?.syncShapeLayers()
        } else {
            editor.notifyTimelineChanged()
        }
        return .ok("Applied '\(preset.rawValue)' to \(clipId).")
    }

    // MARK: - Helpers

    private func parsePreset(_ raw: String?, kind: AnimationPreset.Kind, path: String) throws -> AnimationPreset? {
        guard let raw else { return nil }
        guard let p = AnimationPreset(rawValue: raw) else {
            throw ToolError("\(path): unknown preset '\(raw)'")
        }
        guard p.kind == kind else {
            throw ToolError("\(path): '\(raw)' is a \(p.kind) preset; expected a \(kind) preset")
        }
        return p
    }

    private func applyOptionalAnimation(
        _ preset: AnimationPreset?,
        windowFrames: Int?,
        clipId: String,
        editor: EditorViewModel,
        notes: inout [String]
    ) {
        guard let preset, let loc = editor.findClip(id: clipId) else { return }
        let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        applyPreset(preset, windowFrames: windowFrames, intensity: .medium, clipId: clipId, restingTransform: clip.transform, clipDurationFrames: clip.durationFrames, editor: editor)
        notes.append(preset.rawValue)
    }

    private func applyPreset(
        _ preset: AnimationPreset,
        windowFrames: Int?,
        intensity: AnimationIntensity,
        clipId: String,
        restingTransform: Transform,
        clipDurationFrames: Int,
        editor: EditorViewModel
    ) {
        let application = AnimationPresetEngine.apply(
            preset: preset,
            windowFrames: windowFrames,
            clipDurationFrames: clipDurationFrames,
            restingTransform: restingTransform,
            intensity: intensity
        )
        editor.commitClipProperty(clipId: clipId) { clip in
            AnimationPresetEngine.merge(application, into: &clip)
        }
    }
}
