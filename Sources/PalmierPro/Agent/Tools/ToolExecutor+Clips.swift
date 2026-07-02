import Foundation

// MARK: - Input shapes (Decodable)

fileprivate struct AddClipsInput: DecodableToolArgs {
    let entries: [Entry]
    static let allowedKeys: Set<String> = ["entries"]

    struct Entry: DecodableToolArgs {
        let mediaRef: String
        let trackIndex: Int?
        let startFrame: Int
        let durationFrames: Int?
        let trimStartFrame: Int?
        let trimEndFrame: Int?
        static let allowedKeys: Set<String> = ["mediaRef", "trackIndex", "startFrame", "durationFrames", "trimStartFrame", "trimEndFrame"]
    }
}

fileprivate struct InsertClipsInput: DecodableToolArgs {
    let trackIndex: Int
    let atFrame: Int
    let entries: [Entry]
    static let allowedKeys: Set<String> = ["trackIndex", "atFrame", "entries"]

    struct Entry: DecodableToolArgs {
        let mediaRef: String
        let durationFrames: Int?
        let trimStartFrame: Int?
        let trimEndFrame: Int?
        static let allowedKeys: Set<String> = ["mediaRef", "durationFrames", "trimStartFrame", "trimEndFrame"]
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

fileprivate struct SplitClipsInput: DecodableToolArgs {
    let splits: [Split]?
    let trackIndex: Int?
    let frames: [Int]?
    static let allowedKeys: Set<String> = ["splits", "trackIndex", "frames"]

    struct Split: DecodableToolArgs {
        let clipId: String
        let atFrame: Int
        static let allowedKeys: Set<String> = ["clipId", "atFrame"]
    }
}

fileprivate struct SetClipPropertiesInput: DecodableToolArgs {
    let clipIds: [String]?
    let durationFrames: Int?
    let trimStartFrame: Int?
    let trimEndFrame: Int?
    let speed: Double?
    let volume: Double?
    let opacity: Double?
    let transform: ParsedTransform?
    let blendMode: String?

    static let allowedKeys: Set<String> = Set([
        "clipIds",
        "durationFrames", "trimStartFrame", "trimEndFrame", "speed",
        "volume", "opacity",
        "transform",
        "blendMode",
    ])

    var hasAnyProperty: Bool {
        durationFrames != nil || trimStartFrame != nil || trimEndFrame != nil
            || speed != nil || volume != nil || opacity != nil
            || transform != nil
            || blendMode != nil
    }
}

fileprivate struct RippleDeleteRangesInput: DecodableToolArgs {
    let clipId: String?
    let trackIndex: Int?
    let ranges: [[Double]]
    let units: String?
    let ignoreSyncLockedTracks: [Int]?
    static let allowedKeys: Set<String> = ["clipId", "trackIndex", "ranges", "units", "ignoreSyncLockedTracks"]
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
    let trimStartFrame: Int?
    let trimEndFrame: Int?
}

fileprivate struct ParsedMove {
    let clipId: String
    let destTrackId: String?
    let toFrame: Int?
}

// MARK: - Handlers

extension ToolExecutor {

    /// Resolves (trimStart, duration, trimEnd) for a clip placement
    fileprivate func resolvePlacement(
        _ asset: MediaAsset, fps: Int,
        durationFrames: Int?, trimStartFrame: Int?, trimEndFrame: Int?, path: String
    ) throws -> (trimStart: Int, duration: Int, trimEnd: Int?) {
        let trimStart = trimStartFrame ?? 0
        guard trimStart >= 0 else { throw ToolError("\(path): trimStartFrame must be >= 0 (got \(trimStart))") }
        if let t = trimEndFrame, t < 0 { throw ToolError("\(path): trimEndFrame must be >= 0 (got \(t))") }
        if let d = durationFrames, d < 1 { throw ToolError("\(path): durationFrames must be >= 1 (got \(d))") }
        guard durationFrames == nil || trimEndFrame == nil else {
            throw ToolError("\(path): set durationFrames OR trimEndFrame, not both — both define the clip's end. Use durationFrames for an explicit length, trimEndFrame to trim the tail.")
        }

        let sourceLen = secondsToFrame(seconds: asset.duration, fps: fps)
        if let d = durationFrames {
            if sourceLen > 0, trimStart + d > sourceLen {
                throw ToolError("\(path): trimStartFrame \(trimStart) + durationFrames \(d) exceed the source length (\(sourceLen) frames). Use a shorter durationFrames or smaller trimStartFrame.")
            }
            return (trimStart, d, nil)
        }
        // Length derived from the trimmed source window [trimStart, sourceLen - trimEnd].
        guard sourceLen > 0 else {
            throw ToolError("\(path): durationFrames is required for this asset — its source length is unknown.")
        }
        let trimEnd = trimEndFrame ?? 0
        let duration = sourceLen - trimStart - trimEnd
        guard duration >= 1 else {
            throw ToolError("\(path): trimStartFrame \(trimStart) + trimEndFrame \(trimEnd) leave no frames (source is \(sourceLen)).")
        }
        return (trimStart, duration, trimEndFrame)
    }

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

        var prepared: [(entry: AddClipsInput.Entry, asset: MediaAsset, trackId: String?)] = []
        prepared.reserveCapacity(input.entries.count)
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
            guard entry.startFrame >= 0 else {
                throw ToolError("entries[\(idx)]: startFrame must be >= 0 (got \(entry.startFrame))")
            }
            prepared.append((entry, asset, trackId))
        }

        // All-or-none for trackIndex: a new track at index 0 would shift any explicit indices.
        let omittedCount = prepared.filter { $0.trackId == nil }.count
        guard omittedCount == 0 || omittedCount == prepared.count else {
            throw ToolError("Mixed trackIndex: \(omittedCount) of \(prepared.count) entries omitted trackIndex. Either set it on every entry or omit it on every entry (to auto-create shared tracks).")
        }

        let settingsNote = applySettingsIfNeededForAgent(editor, assets: prepared.map(\.asset))

        var specs: [AddClipSpec] = []
        specs.reserveCapacity(prepared.count)
        for (idx, p) in prepared.enumerated() {
            let place = try resolvePlacement(p.asset, fps: editor.timeline.fps,
                                             durationFrames: p.entry.durationFrames,
                                             trimStartFrame: p.entry.trimStartFrame,
                                             trimEndFrame: p.entry.trimEndFrame, path: "entries[\(idx)]")
            specs.append(.init(asset: p.asset, trackId: p.trackId, startFrame: p.entry.startFrame,
                               durationFrames: place.duration, trimStartFrame: place.trimStart, trimEndFrame: place.trimEnd))
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
                    startFrame: spec.startFrame, durationFrames: spec.durationFrames,
                    trimStartFrame: spec.trimStartFrame, trimEndFrame: spec.trimEndFrame
                )
                guard let primary = ids.first else {
                    throw ToolError("entries[\(i)]: failed to place clip on track \(trackIdx) at frame \(spec.startFrame)")
                }
                allAdded.append(contentsOf: ids)
                let pairedNote = ids.count > 1 ? " (+linked audio \(ids[1]))" : ""
                var trimNote = ""
                if let t = spec.trimStartFrame, t != 0 { trimNote += " trimStart \(t)" }
                if let t = spec.trimEndFrame, t != 0 { trimNote += " trimEnd \(t)" }
                summaries.append("\(primary) on track \(trackIdx) @ \(spec.startFrame) for \(spec.durationFrames)\(trimNote)\(pairedNote)")
            }

            for track in editor.timeline.tracks where track.clips.isEmpty && nonEmptyBefore.contains(track.id) {
                editor.removeTrack(id: track.id)
            }

            for (idx, track) in editor.timeline.tracks.enumerated()
                where !tracksBefore.contains(track.id) && !reportedTrackIds.contains(track.id) {
                reportTrack(idx)
            }
            let addedIds = allAdded
            editor.registerTimelineUndo { vm in
                vm.removeClips(ids: Set(addedIds))
            }
            return (createdTracks, summaries)
        }
        editor.notifyTimelineChanged()

        var prefix = createdTracks.isEmpty ? "" : "Created \(createdTracks.joined(separator: ", ")). "
        if let note = settingsNote { prefix = "\(note) \(prefix)" }
        return .ok("\(prefix)Added \(specs.count) clip\(specs.count == 1 ? "" : "s"): \(summaries.joined(separator: "; "))")
    }

    // MARK: insert_clips

    func insertClips(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: InsertClipsInput = try decodeToolArgs(args, path: "insert_clips")
        guard !input.entries.isEmpty else { throw ToolError("Missing or empty 'entries' array") }
        if let raws = args["entries"] as? [Any] {
            for (idx, raw) in raws.enumerated() {
                if let d = raw as? [String: Any] {
                    try validateUnknownKeys(d, allowed: InsertClipsInput.Entry.allowedKeys, path: "entries[\(idx)]")
                }
            }
        }
        guard editor.timeline.tracks.indices.contains(input.trackIndex) else {
            throw ToolError("trackIndex \(input.trackIndex) out of range (0..\(editor.timeline.tracks.count - 1))")
        }
        guard input.atFrame >= 0 else { throw ToolError("atFrame must be >= 0 (got \(input.atFrame))") }
        let targetType = editor.timeline.tracks[input.trackIndex].type

        // Apply settings before deriving durations: it may change FPS, which clipDurationFrames depends on.
        var resolvedAssets: [MediaAsset] = []
        resolvedAssets.reserveCapacity(input.entries.count)
        for (idx, entry) in input.entries.enumerated() {
            let asset = try asset(entry.mediaRef, editor: editor)
            guard asset.type.isCompatible(with: targetType) else {
                throw ToolError("entries[\(idx)]: asset type \(asset.type.rawValue) is not compatible with \(targetType.rawValue) track at index \(input.trackIndex)")
            }
            resolvedAssets.append(asset)
        }

        let settingsNote = applySettingsIfNeededForAgent(editor, assets: resolvedAssets)

        var specs: [EditorViewModel.RippleInsertSpec] = []
        specs.reserveCapacity(input.entries.count)
        for (idx, entry) in input.entries.enumerated() {
            let place = try resolvePlacement(resolvedAssets[idx], fps: editor.timeline.fps,
                                             durationFrames: entry.durationFrames,
                                             trimStartFrame: entry.trimStartFrame,
                                             trimEndFrame: entry.trimEndFrame, path: "entries[\(idx)]")
            specs.append(.init(asset: resolvedAssets[idx], durationFrames: place.duration,
                               trimStartFrame: place.trimStart, trimEndFrame: place.trimEnd))
        }

        let totalPush = specs.reduce(0) { $0 + $1.durationFrames }
        let tracksBefore = editor.timeline.tracks.count
        let ids = editor.rippleInsertClips(specs: specs, trackIndex: input.trackIndex, atFrame: input.atFrame)
        guard !ids.isEmpty else {
            throw ToolError("Insert failed on track \(input.trackIndex) at frame \(input.atFrame)")
        }
        let audioNote = editor.timeline.tracks.count > tracksBefore
            ? " Created an audio track (appended) for the linked audio." : ""
        let settingsPrefix = settingsNote.map { "\($0) " } ?? ""
        return .ok("\(settingsPrefix)Inserted \(specs.count) clip\(specs.count == 1 ? "" : "s") at frame \(input.atFrame) on track \(input.trackIndex), pushed later clips +\(totalPush)f: \(ids.joined(separator: ", ")).\(audioNote)")
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

    func setClipProperties(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: SetClipPropertiesInput = try decodeToolArgs(args, path: "set_clip_properties")
        let clipIds = input.clipIds ?? []
        guard !clipIds.isEmpty else { throw ToolError("Provide a non-empty 'clipIds' array") }
        guard input.hasAnyProperty else {
            throw ToolError("set_clip_properties needs at least one property to apply")
        }
        if let df = input.durationFrames, df < 1 {
            throw ToolError("durationFrames must be >= 1 (got \(df))")
        }
        if let s = input.speed, s <= 0 {
            throw ToolError("speed must be > 0 (got \(s))")
        }
        if let v = input.volume, !(0...1).contains(v) {
            throw ToolError("volume must be between 0 and 1 (got \(v))")
        }
        if let o = input.opacity, !(0...1).contains(o) {
            throw ToolError("opacity must be between 0 and 1 (got \(o))")
        }
        if let t = input.trimStartFrame, t < 0 {
            throw ToolError("trimStartFrame must be >= 0 (got \(t))")
        }
        if let t = input.trimEndFrame, t < 0 {
            throw ToolError("trimEndFrame must be >= 0 (got \(t))")
        }

        // Resolve clipIds + collect types for blend-mode validation.
        var clipTypes: [String: ClipType] = [:]
        for id in clipIds {
            guard let loc = editor.findClip(id: id) else { throw ToolError("Clip not found: \(id)") }
            clipTypes[id] = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].mediaType
        }

        // blendMode applies only to visual (video/image) clips. "normal" clears it.
        var blendMode: BlendMode?
        let setBlendMode = input.blendMode != nil
        if let raw = input.blendMode {
            let nonVisual = clipTypes.filter { $0.value == .text || $0.value == .audio }.map(\.key).sorted()
            if !nonVisual.isEmpty {
                throw ToolError("blendMode only applies to video/image clips: \(nonVisual.joined(separator: ", "))")
            }
            if raw != "normal" {
                guard let m = BlendMode(rawValue: raw) else {
                    throw ToolError("invalid blendMode '\(raw)'. Valid: \(BlendMode.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                blendMode = m
            }
        }

        // Expand timing fields to linked partners via the shared model helper.
        // Partners drop trim/speed when they're text — handled per-partner below.
        let propagatesTiming = input.durationFrames != nil || input.trimStartFrame != nil
            || input.trimEndFrame != nil || input.speed != nil
        let partners: Set<String> = propagatesTiming
            ? editor.timingPropagationPartners(of: Set(clipIds))
            : []

        let setActionName = clipIds.count == 1 ? "Set Clip Property (Agent)" : "Set Clip Properties (Agent)"
        let summaries: [String] = withUndoGroup(editor, actionName: setActionName) {
            var summaries: [String] = []
            for id in clipIds {
                let changed = Self.applyPropertyChanges(
                    durationFrames: input.durationFrames,
                    trimStartFrame: input.trimStartFrame,
                    trimEndFrame: input.trimEndFrame,
                    speed: input.speed,
                    volume: input.volume,
                    opacity: input.opacity,
                    transform: input.transform,
                    blendMode: blendMode,
                    setBlendMode: setBlendMode,
                    clipId: id,
                    editor: editor
                )
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
                    blendMode: nil, setBlendMode: false,
                    clipId: partnerId,
                    editor: editor
                )
            }
            return summaries
        }

        let linkedNote = partners.isEmpty ? "" : " (+\(partners.count) linked)"
        return .ok("Updated \(clipIds.count) clip\(clipIds.count == 1 ? "" : "s")\(linkedNote): \(summaries.joined(separator: "; "))")
    }

    fileprivate static func applyPropertyChanges(
        durationFrames: Int?,
        trimStartFrame: Int?,
        trimEndFrame: Int?,
        speed: Double?,
        volume: Double?,
        opacity: Double?,
        transform: ParsedTransform?,
        blendMode: BlendMode?,
        setBlendMode: Bool,
        clipId: String,
        editor: EditorViewModel
    ) -> [String] {
        var changed: [String] = []
        editor.commitClipProperty(clipId: clipId) { clip in
            if let v = durationFrames {
                clip.setDuration(v)
                changed.append("durationFrames")
            }
            if let v = trimStartFrame { clip.trimStartFrame = v; changed.append("trimStartFrame") }
            if let v = trimEndFrame   { clip.trimEndFrame   = v; changed.append("trimEndFrame") }
            if let v = speed {
                if durationFrames == nil, v > 0 {
                    let sourceConsumed = Double(clip.durationFrames) * clip.speed
                    clip.setDuration(max(1, safeInt((sourceConsumed / v).rounded()) ?? clip.durationFrames))
                    changed.append("durationFrames")
                }
                clip.speed = v
                changed.append("speed")
            }
            // Setting a scalar clears any existing keyframe track on the same property.
            if let v = volume         { clip.volume  = v; clip.volumeTrack  = nil; changed.append("volume") }
            if let v = opacity        { clip.opacity = v; clip.opacityTrack = nil; changed.append("opacity") }
            if setBlendMode           { clip.blendMode = blendMode; changed.append("blendMode") }
            if let t = transform {
                let cur = clip.transform
                var next = Transform(
                    center: (t.centerX ?? cur.center.x, t.centerY ?? cur.center.y),
                    width: t.width ?? cur.width,
                    height: t.height ?? cur.height
                )
                next.rotation = cur.rotation
                next.flipHorizontal = t.flipHorizontal ?? cur.flipHorizontal
                next.flipVertical = t.flipVertical ?? cur.flipVertical
                clip.transform = next
                changed.append("transform")
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

    // MARK: split_clips

    func splitClips(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: SplitClipsInput = try decodeToolArgs(args, path: "split_clips")
        let hasSplits = !(input.splits ?? []).isEmpty
        let hasTrack = input.trackIndex != nil || !(input.frames ?? []).isEmpty
        guard hasSplits != hasTrack else {
            throw ToolError("Provide exactly one of 'splits' (an array of {clipId, atFrame}) or 'trackIndex'+'frames' (project frames to cut on one track).")
        }

        // Resolve every cut to a (trackIndex, atFrame) pair against the CURRENT timeline
        var points: [(trackIndex: Int, atFrame: Int)] = []
        var seen: Set<String> = []

        func addCut(trackIndex: Int, atFrame: Int, clip: Clip) throws {
            guard atFrame > clip.startFrame && atFrame < clip.endFrame else {
                throw ToolError("Frame \(atFrame) is outside clip \(clip.id) range (\(clip.startFrame)..\(clip.endFrame))")
            }
            let key = "\(trackIndex):\(atFrame)"
            guard seen.insert(key).inserted else { return }
            points.append((trackIndex, atFrame))
        }

        if hasSplits {
            for s in input.splits ?? [] {
                guard let loc = editor.findClip(id: s.clipId) else { throw ToolError("Clip not found: \(s.clipId)") }
                let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
                try addCut(trackIndex: loc.trackIndex, atFrame: s.atFrame, clip: clip)
            }
        } else {
            guard let trackIndex = input.trackIndex,
                  trackIndex >= 0, trackIndex < editor.timeline.tracks.count else {
                throw ToolError("trackIndex is required and must be in 0..\(editor.timeline.tracks.count - 1)")
            }
            guard let frames = input.frames, !frames.isEmpty else {
                throw ToolError("'frames' must be a non-empty array of project frames")
            }
            let track = editor.timeline.tracks[trackIndex]
            for f in frames {
                guard let clip = track.clips.first(where: { f > $0.startFrame && f < $0.endFrame }) else {
                    throw ToolError("Frame \(f) is not strictly inside any clip on track \(trackIndex)")
                }
                try addCut(trackIndex: trackIndex, atFrame: f, clip: clip)
            }
        }

        guard !points.isEmpty else { throw ToolError("No valid split points") }
        let rightIds = editor.splitClips(at: points)
        let cutList = points
            .sorted { $0.trackIndex == $1.trackIndex ? $0.atFrame < $1.atFrame : $0.trackIndex < $1.trackIndex }
            .map { "track \($0.trackIndex)@\($0.atFrame)" }
            .joined(separator: ", ")
        let newNote = rightIds.isEmpty ? "" : " New right-half clip(s): \(rightIds.joined(separator: ", "))."
        return .ok("Split \(points.count) point(s) [\(cutList)].\(newNote) Re-read with get_timeline for updated ranges.")
    }

    // MARK: ripple_delete_ranges

    func rippleDeleteRanges(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: RippleDeleteRangesInput = try decodeToolArgs(args, path: "ripple_delete_ranges")
        guard !input.ranges.isEmpty else { throw ToolError("Missing or empty 'ranges' array") }
        let units = input.units ?? "frames"
        guard units == "seconds" || units == "frames" else {
            throw ToolError("units must be 'seconds' or 'frames' (got '\(units)')")
        }
        guard (input.clipId != nil) != (input.trackIndex != nil) else {
            throw ToolError("Provide exactly one of 'clipId' (cut within a single clip; allows 'seconds') or 'trackIndex' (cut project-frame ranges spanning a whole track in one call).")
        }
        let fps = editor.timeline.fps

        for (i, r) in input.ranges.enumerated() {
            guard r.count == 2 else {
                throw ToolError("ranges[\(i)]: expected [start, end] (got \(r.count) element\(r.count == 1 ? "" : "s"))")
            }
            guard r[1] > r[0] else {
                throw ToolError("ranges[\(i)]: end (\(r[1])) must be greater than start (\(r[0]))")
            }
        }

        var frameRanges: [FrameRange] = []
        var dropped = 0
        let resolvedTrackIndex: Int

        if let clipId = input.clipId {
            guard let loc = editor.findClip(id: clipId) else { throw ToolError("Clip not found: \(clipId)") }
            let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            // 'frames' are project frames as-is; 'seconds' are source seconds → map through trim/speed/position.
            func toFrame(_ v: Double) -> Double {
                units == "frames"
                    ? v
                    : Double(clip.startFrame) + (v * Double(fps) - Double(clip.trimStartFrame)) / max(clip.speed, 0.0001)
            }
            for r in input.ranges {
                let s = clampInt(toFrame(r[0]), min: clip.startFrame, max: clip.endFrame)
                let e = clampInt(toFrame(r[1]), min: clip.startFrame, max: clip.endFrame)
                if e > s { frameRanges.append(FrameRange(start: s, end: e)) } else { dropped += 1 }
            }
            guard !frameRanges.isEmpty else {
                throw ToolError("No ranges fall within clip \(clipId) (frames \(clip.startFrame)..\(clip.endFrame)). In '\(units)' units, ranges must overlap the clip's visible span.")
            }
            resolvedTrackIndex = loc.trackIndex
        } else {
            let trackIndex = input.trackIndex!
            guard units == "frames" else {
                throw ToolError("units 'seconds' requires a clipId for source-media mapping; with trackIndex, ranges are project frames.")
            }
            guard editor.timeline.tracks.indices.contains(trackIndex) else {
                throw ToolError("Track index out of range: \(trackIndex)")
            }
            for r in input.ranges {
                let s = clampInt(r[0], min: 0, max: editor.timeline.totalFrames)
                let e = clampInt(r[1], min: 0, max: editor.timeline.totalFrames)
                if e > s { frameRanges.append(FrameRange(start: s, end: e)) } else { dropped += 1 }
            }
            guard !frameRanges.isEmpty else {
                throw ToolError("No valid project-frame ranges to delete on track \(trackIndex).")
            }
            resolvedTrackIndex = trackIndex
        }

        let ignoreSyncLocked = Set(input.ignoreSyncLockedTracks ?? [])
        switch editor.rippleDeleteRangesOnTrack(trackIndex: resolvedTrackIndex, ranges: frameRanges, ignoreSyncLockTrackIndices: ignoreSyncLocked) {
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
        if let v = raw as? Double, let i = safeInt(v) { return i }
        if let v = raw as? NSNumber, let i = safeInt(v.doubleValue) { return i }
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
