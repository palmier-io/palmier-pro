import Foundation

// MARK: - Input shapes (Decodable)

fileprivate struct AddClipsInput: DecodableToolArgs {
    let entries: [Entry]
    static let allowedKeys: Set<String> = ["entries"]

    struct Entry: DecodableToolArgs {
        let mediaRef: String
        let trackIndex: Int?
        let startFrame: Int
        let endFrame: Int?
        let source: [Double]?
        static let allowedKeys: Set<String> = ["mediaRef", "trackIndex", "startFrame", "endFrame", "source"]
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
        let source: [Double]?
        static let allowedKeys: Set<String> = ["mediaRef", "durationFrames", "source"]
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
    let volumeDb: Double?
    let opacity: Double?
    let fadeInFrames: Int?
    let fadeOutFrames: Int?
    let fadeInInterpolation: String?
    let fadeOutInterpolation: String?
    let edgeRounding: Double?
    let edgeSoftness: Double?
    let transform: ParsedTransform?
    let blendMode: String?

    static let allowedKeys: Set<String> = Set([
        "clipIds",
        "durationFrames", "trimStartFrame", "trimEndFrame", "speed",
        "volumeDb", "opacity",
        "fadeInFrames", "fadeOutFrames", "fadeInInterpolation", "fadeOutInterpolation",
        "edgeRounding", "edgeSoftness",
        "transform",
        "blendMode",
    ])

    var hasAnyProperty: Bool {
        durationFrames != nil || trimStartFrame != nil || trimEndFrame != nil
            || speed != nil || volumeDb != nil || opacity != nil
            || fadeInFrames != nil || fadeOutFrames != nil
            || fadeInInterpolation != nil || fadeOutInterpolation != nil
            || edgeRounding != nil || edgeSoftness != nil
            || transform?.hasAnyField == true
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

/// Partial transform shared by clip and text property tools.
struct ParsedTransform: Decodable {
    var centerX: Double?
    var centerY: Double?
    var width: Double?
    var height: Double?
    var rotation: Double?
    var flipHorizontal: Bool?
    var flipVertical: Bool?

    static let allowedKeys: Set<String> = [
        "centerX", "centerY", "width", "height", "rotation", "flipHorizontal", "flipVertical",
    ]

    var hasLayoutField: Bool {
        centerX != nil || centerY != nil || width != nil || height != nil
    }

    var hasAnyField: Bool {
        hasLayoutField || rotation != nil
            || flipHorizontal != nil || flipVertical != nil
    }

    func apply(to clip: inout Clip) {
        if let centerX { clip.transform.centerX = centerX }
        if let centerY { clip.transform.centerY = centerY }
        if let width { clip.transform.width = width }
        if let height { clip.transform.height = height }
        if let rotation { clip.transform.rotation = rotation; clip.rotationTrack = nil }
        if let flipHorizontal { clip.transform.flipHorizontal = flipHorizontal }
        if let flipVertical { clip.transform.flipVertical = flipVertical }
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

    /// Resolves (trimStart, duration, trimEnd) for a clip placement. One length expression per
    /// domain: `source: [startSeconds, endSeconds]` picks a span of the asset (unclamped for
    /// stills — an image is an unbounded still), an exact frame count pins the timeline length.
    fileprivate func resolvePlacement(
        _ asset: MediaAsset, fps: Int,
        durationFrames: Int?, source: [Double]?, path: String, framesLabel: String = "durationFrames"
    ) throws -> (trimStart: Int, duration: Int, trimEnd: Int?) {
        guard durationFrames == nil || source == nil else {
            throw ToolError("\(path): set source OR \(framesLabel), not both — source picks a span of the asset, \(framesLabel) an exact timeline length.")
        }
        let isStill = asset.type == .image
        let sourceLen = secondsToFrame(seconds: asset.duration, fps: fps)

        if let source {
            guard source.count == 2 else {
                throw ToolError("\(path): source must be [startSeconds, endSeconds] (got \(source.count) element\(source.count == 1 ? "" : "s"))")
            }
            guard asset.duration > 0 || isStill else {
                throw ToolError("\(path): source needs a known source length; this asset has none. Use \(framesLabel).")
            }
            let start = max(source[0], 0)
            let end = isStill ? source[1] : min(source[1], asset.duration)
            guard end > start else {
                throw ToolError("\(path): source end (\(source[1])) must be greater than start (\(source[0]))\(isStill ? "" : "; source is \(asset.duration)s").")
            }
            let trimStart = secondsToFrame(seconds: start, fps: fps)
            let duration = max(1, secondsToFrame(seconds: end, fps: fps) - trimStart)
            return (trimStart, duration, nil)
        }
        if let d = durationFrames {
            guard d >= 1 else { throw ToolError("\(path): \(framesLabel) must span at least 1 frame") }
            if !isStill, sourceLen > 0, d > sourceLen {
                throw ToolError("\(path): \(framesLabel) spans \(d) frames but the source is only \(sourceLen).")
            }
            return (0, d, nil)
        }
        guard sourceLen > 0 else {
            throw ToolError("\(path): \(framesLabel) is required for this asset — its source length is unknown.")
        }
        return (0, sourceLen, nil)
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
            let asset = try clipSource(entry.mediaRef, editor: editor, path: "entries[\(idx)]")
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

        var specs: [AddClipSpec] = []
        specs.reserveCapacity(prepared.count)
        for (idx, p) in prepared.enumerated() {
            if let end = p.entry.endFrame, end <= p.entry.startFrame {
                throw ToolError("entries[\(idx)]: endFrame (\(end)) must be greater than startFrame (\(p.entry.startFrame))")
            }
            let place = try resolvePlacement(p.asset, fps: editor.timeline.fps,
                                             durationFrames: p.entry.endFrame.map { $0 - p.entry.startFrame },
                                             source: p.entry.source, path: "entries[\(idx)]", framesLabel: "endFrame")
            specs.append(.init(asset: p.asset, trackId: p.trackId, startFrame: p.entry.startFrame,
                               durationFrames: place.duration, trimStartFrame: place.trimStart, trimEndFrame: place.trimEnd))
        }

        let snapshot = timelineSnapshot(editor)
        let actionName = specs.count == 1 ? "Add Clip (Agent)" : "Add Clips (Agent)"
        var settingsNote: String?
        try editor.undo.perform(actionName) {
            settingsNote = applySettingsIfNeededForAgent(
                editor,
                assets: prepared.map(\.asset).filter { $0.type != .sequence }
            )
            if omittedCount == specs.count {
                let needsVideo = specs.contains { $0.asset.type != .audio }
                let needsAudio = specs.contains { $0.asset.type == .audio }
                var videoTrackId: String? = nil
                var audioTrackId: String? = nil
                if needsVideo {
                    videoTrackId = editor.timeline.tracks[editor.insertTrack(at: 0, type: .video)].id
                }
                if needsAudio {
                    audioTrackId = editor.timeline.tracks[
                        editor.insertTrack(at: editor.timeline.tracks.count, type: .audio)
                    ].id
                }
                for i in specs.indices {
                    specs[i].trackId = (specs[i].asset.type == .audio) ? audioTrackId : videoTrackId
                }
            }

            var allAdded: [String] = []
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
                guard !ids.isEmpty else {
                    throw ToolError("entries[\(i)]: failed to place clip on track \(trackIdx) at frame \(spec.startFrame)")
                }
                allAdded.append(contentsOf: ids)
            }

            for track in editor.timeline.tracks where track.clips.isEmpty && nonEmptyBefore.contains(track.id) {
                editor.removeTrack(id: track.id)
            }

            let addedIds = allAdded
            editor.registerTimelineUndo(actionName) { vm in
                vm.removeClips(ids: Set(addedIds))
            }
        }
        editor.notifyTimelineChanged()
        return mutationResult(editor, since: snapshot, notes: settingsNote.map { [$0] } ?? [])
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

        var resolvedAssets: [MediaAsset] = []
        resolvedAssets.reserveCapacity(input.entries.count)
        for (idx, entry) in input.entries.enumerated() {
            let asset = try clipSource(entry.mediaRef, editor: editor, path: "entries[\(idx)]")
            guard asset.type.isCompatible(with: targetType) else {
                throw ToolError("entries[\(idx)]: asset type \(asset.type.rawValue) is not compatible with \(targetType.rawValue) track at index \(input.trackIndex)")
            }
            resolvedAssets.append(asset)
        }

        var specs: [EditorViewModel.RippleInsertSpec] = []
        specs.reserveCapacity(input.entries.count)
        for (idx, entry) in input.entries.enumerated() {
            let place = try resolvePlacement(resolvedAssets[idx], fps: editor.timeline.fps,
                                             durationFrames: entry.durationFrames,
                                             source: entry.source, path: "entries[\(idx)]")
            specs.append(.init(asset: resolvedAssets[idx], durationFrames: place.duration,
                               trimStartFrame: place.trimStart, trimEndFrame: place.trimEnd))
        }

        let snapshot = timelineSnapshot(editor)
        var settingsNote: String?
        let ids = editor.undo.perform(specs.count == 1 ? "Insert Clip (Agent)" : "Insert Clips (Agent)") {
            settingsNote = applySettingsIfNeededForAgent(
                editor,
                assets: resolvedAssets.filter { $0.type != .sequence }
            )
            return editor.rippleInsertClips(specs: specs, trackIndex: input.trackIndex, atFrame: input.atFrame)
        }
        guard !ids.isEmpty else {
            throw ToolError("Insert failed on track \(input.trackIndex) at frame \(input.atFrame)")
        }
        return mutationResult(editor, since: snapshot, notes: settingsNote.map { [$0] } ?? [])
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
        let snapshot = timelineSnapshot(editor)
        editor.undo.perform(clipIds.count == 1 ? "Remove Clip (Agent)" : "Remove Clips (Agent)") {
            editor.removeClips(ids: expanded)
        }
        return mutationResult(editor, since: snapshot)
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
        if let reason = editor.multicamMoveViolation(moves: moves) {
            throw ToolError(reason)
        }

        let snapshot = timelineSnapshot(editor)
        let moveActionName = parsed.count == 1 ? "Move Clip (Agent)" : "Move Clips (Agent)"
        editor.undo.perform(moveActionName) {
            if !moves.isEmpty { editor.moveClips(moves) }
        }

        return mutationResult(editor, since: snapshot, touched: allMoves.map(\.clipId))
    }

    // MARK: set_clip_properties

    func setClipProperties(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        if let rawTransform = args["transform"] {
            guard let transform = rawTransform as? [String: Any] else {
                throw ToolError("set_clip_properties.transform: expected object")
            }
            try validateUnknownKeys(
                transform,
                allowed: ParsedTransform.allowedKeys,
                path: "set_clip_properties.transform"
            )
        }
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
        if let v = input.volumeDb, !(VolumeScale.floorDb...VolumeScale.ceilingDb).contains(v) {
            throw ToolError("volumeDb must be between \(VolumeScale.floorDb) and +\(VolumeScale.ceilingDb) dB (got \(v))")
        }
        if let o = input.opacity, !(0...1).contains(o) {
            throw ToolError("opacity must be between 0 and 1 (got \(o))")
        }
        if let frames = input.fadeInFrames, frames < 0 {
            throw ToolError("fadeInFrames must be >= 0 (got \(frames))")
        }
        if let frames = input.fadeOutFrames, frames < 0 {
            throw ToolError("fadeOutFrames must be >= 0 (got \(frames))")
        }
        let fadeInInterpolation = try Self.fadeInterpolation(
            input.fadeInInterpolation,
            field: "fadeInInterpolation"
        )
        let fadeOutInterpolation = try Self.fadeInterpolation(
            input.fadeOutInterpolation,
            field: "fadeOutInterpolation"
        )
        for (name, value) in [
            ("edgeRounding", input.edgeRounding),
            ("edgeSoftness", input.edgeSoftness),
        ] {
            guard let value else { continue }
            guard value.isFinite, (0...1).contains(value) else {
                throw ToolError("\(name) must be between 0 and 1 (got \(value))")
            }
        }
        if let t = input.trimStartFrame, t < 0 {
            throw ToolError("trimStartFrame must be >= 0 (got \(t))")
        }
        if let t = input.trimEndFrame, t < 0 {
            throw ToolError("trimEndFrame must be >= 0 (got \(t))")
        }

        // Resolve clipIds + collect clips for validation.
        var targetClips: [String: Clip] = [:]
        for id in clipIds {
            guard let loc = editor.findClip(id: id) else { throw ToolError("Clip not found: \(id)") }
            targetClips[id] = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        }

        if clipIds.contains(where: { editor.clipFor(id: $0)?.multicamGroupId != nil }),
           input.trimStartFrame != nil || input.trimEndFrame != nil || input.durationFrames != nil || input.speed != nil {
            throw ToolError("Timing fields would slip a multicam clip out of sync — switch angles with change_cam; split/delete and property fields (volumeDb, opacity, edgeRounding, edgeSoftness, transform) stay editable.")
        }

        if input.fadeInFrames != nil || input.fadeOutFrames != nil {
            for id in clipIds {
                guard var candidate = targetClips[id] else { continue }
                _ = Self.applyTimingChanges(
                    durationFrames: input.durationFrames,
                    trimStartFrame: input.trimStartFrame,
                    trimEndFrame: input.trimEndFrame,
                    speed: input.speed,
                    to: &candidate
                )
                let fadeInFrames = input.fadeInFrames ?? candidate.fadeInFrames
                let fadeOutFrames = input.fadeOutFrames ?? candidate.fadeOutFrames
                guard fadeInFrames <= candidate.durationFrames,
                      fadeOutFrames <= candidate.durationFrames - fadeInFrames else {
                    throw ToolError(
                        "Fades for clip \(id) must fit within its resulting duration of \(candidate.durationFrames) frames "
                            + "(fadeInFrames \(fadeInFrames) + fadeOutFrames \(fadeOutFrames))"
                    )
                }
            }
        }

        // blendMode applies only to visual (video/image) clips. "normal" clears it.
        var blendMode: BlendMode?
        let setBlendMode = input.blendMode != nil
        if let raw = input.blendMode {
            let nonVisual = targetClips.filter {
                $0.value.mediaType == .text || $0.value.mediaType == .audio
            }.map(\.key).sorted()
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
        if input.edgeRounding != nil || input.edgeSoftness != nil {
            let unsupported = targetClips.filter {
                $0.value.mediaType == .audio || $0.value.mediaType == .text
            }.map(\.key).sorted()
            if !unsupported.isEmpty {
                throw ToolError("edgeRounding and edgeSoftness only apply to non-text visual clips: \(unsupported.joined(separator: ", "))")
            }
        }

        // Expand timing fields to linked partners via the shared model helper.
        // Partners drop trim/speed when they're text — handled per-partner below.
        let propagatesTiming = input.durationFrames != nil || input.trimStartFrame != nil
            || input.trimEndFrame != nil || input.speed != nil
        let partners: Set<String> = propagatesTiming
            ? editor.timingPropagationPartners(of: Set(clipIds))
            : []

        var notes: [String] = []
        let clearedKeyframes = clipIds.filter { id in
            guard let loc = editor.findClip(id: id) else { return false }
            let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            return (input.volumeDb != nil && clip.volumeTrack != nil)
                || (input.opacity != nil && clip.opacityTrack != nil)
                || (input.transform?.rotation != nil && clip.rotationTrack != nil)
        }
        if !clearedKeyframes.isEmpty {
            notes.append("Setting a static value cleared existing keyframes on: \(clearedKeyframes.joined(separator: ", ")).")
        }

        var beforeClips: [String: Clip] = [:]
        for id in clipIds + Array(partners) {
            beforeClips[id] = editor.clipFor(id: id)
        }

        let snapshot = timelineSnapshot(editor)
        let setActionName = clipIds.count == 1 ? "Set Clip Property (Agent)" : "Set Clip Properties (Agent)"
        editor.undo.perform(setActionName) {
            for id in clipIds {
                let changed = Self.applyPropertyChanges(
                    durationFrames: input.durationFrames,
                    trimStartFrame: input.trimStartFrame,
                    trimEndFrame: input.trimEndFrame,
                    speed: input.speed,
                    volumeDb: input.volumeDb,
                    opacity: input.opacity,
                    fadeInFrames: input.fadeInFrames,
                    fadeOutFrames: input.fadeOutFrames,
                    fadeInInterpolation: fadeInInterpolation,
                    fadeOutInterpolation: fadeOutInterpolation,
                    edgeRounding: input.edgeRounding,
                    edgeSoftness: input.edgeSoftness,
                    transform: input.transform,
                    blendMode: blendMode,
                    setBlendMode: setBlendMode,
                    clipId: id,
                    editor: editor
                )
                notes.append(contentsOf: changed.filter { $0.contains("skipped") }.map { "\(id): \($0)" })
            }
            for partnerId in partners {
                guard let pLoc = editor.findClip(id: partnerId) else { continue }
                let partnerIsText = editor.timeline.tracks[pLoc.trackIndex].clips[pLoc.clipIndex].mediaType == .text
                _ = Self.applyPropertyChanges(
                    durationFrames: input.durationFrames,
                    trimStartFrame: partnerIsText ? nil : input.trimStartFrame,
                    trimEndFrame:   partnerIsText ? nil : input.trimEndFrame,
                    speed:          partnerIsText ? nil : input.speed,
                    volumeDb: nil, opacity: nil,
                    fadeInFrames: nil, fadeOutFrames: nil,
                    fadeInInterpolation: nil, fadeOutInterpolation: nil,
                    edgeRounding: nil, edgeSoftness: nil, transform: nil,
                    blendMode: nil, setBlendMode: false,
                    clipId: partnerId,
                    editor: editor
                )
            }
        }
        let changed = beforeClips.contains { id, clip in editor.clipFor(id: id) != clip }
        return mutationResult(
            editor,
            since: snapshot,
            touched: clipIds + Array(partners),
            extra: ["changed": changed],
            notes: notes
        )
    }

    fileprivate static func applyPropertyChanges(
        durationFrames: Int?,
        trimStartFrame: Int?,
        trimEndFrame: Int?,
        speed: Double?,
        volumeDb: Double?,
        opacity: Double?,
        fadeInFrames: Int?,
        fadeOutFrames: Int?,
        fadeInInterpolation: Interpolation?,
        fadeOutInterpolation: Interpolation?,
        edgeRounding: Double?,
        edgeSoftness: Double?,
        transform: ParsedTransform?,
        blendMode: BlendMode?,
        setBlendMode: Bool,
        clipId: String,
        editor: EditorViewModel
    ) -> [String] {
        var changed: [String] = []
        editor.commitClipProperty(clipId: clipId) { clip in
            changed.append(contentsOf: applyTimingChanges(
                durationFrames: durationFrames,
                trimStartFrame: trimStartFrame,
                trimEndFrame: trimEndFrame,
                speed: speed,
                to: &clip
            ))
            // Setting a scalar clears any existing keyframe track on the same property.
            if let v = volumeDb {
                clip.volume = VolumeScale.linearFromDb(v)
                clip.volumeTrack = nil
                changed.append("volumeDb")
            }
            if let v = opacity        { clip.opacity = v; clip.opacityTrack = nil; changed.append("opacity") }
            if let v = fadeInFrames   { clip.setFade(.left, frames: v); changed.append("fadeInFrames") }
            if let v = fadeOutFrames  { clip.setFade(.right, frames: v); changed.append("fadeOutFrames") }
            if let v = fadeInInterpolation {
                clip.setFadeInterpolation(.left, v)
                changed.append("fadeInInterpolation")
            }
            if let v = fadeOutInterpolation {
                clip.setFadeInterpolation(.right, v)
                changed.append("fadeOutInterpolation")
            }
            if let v = edgeRounding { clip.edgeRounding = v; changed.append("edgeRounding") }
            if let v = edgeSoftness { clip.edgeSoftness = v; changed.append("edgeSoftness") }
            if setBlendMode           { clip.blendMode = blendMode; changed.append("blendMode") }
            if let t = transform {
                t.apply(to: &clip)
                changed.append("transform")
            }
        }
        return changed
    }

    private static func applyTimingChanges(
        durationFrames: Int?,
        trimStartFrame: Int?,
        trimEndFrame: Int?,
        speed: Double?,
        to clip: inout Clip
    ) -> [String] {
        var changed: [String] = []
        if let v = durationFrames {
            clip.setDuration(v)
            changed.append("durationFrames")
        }
        if let v = trimStartFrame { clip.trimStartFrame = v; changed.append("trimStartFrame") }
        if let v = trimEndFrame   { clip.trimEndFrame   = v; changed.append("trimEndFrame") }
        if let v = speed {
            if !clip.supportsRetiming {
                changed.append("speed skipped (nested timelines don't support retiming)")
            } else {
                if durationFrames == nil, v > 0 {
                    let sourceConsumed = Double(clip.durationFrames) * clip.speed
                    clip.setDuration(max(1, safeInt((sourceConsumed / v).rounded()) ?? clip.durationFrames))
                    changed.append("durationFrames")
                }
                clip.speed = v
                changed.append("speed")
            }
        }
        return changed
    }

    private static func fadeInterpolation(_ rawValue: String?, field: String) throws -> Interpolation? {
        guard let rawValue else { return nil }
        guard let value = Interpolation(rawValue: rawValue), value == .linear || value == .smooth else {
            throw ToolError("\(field) must be 'linear' or 'smooth' (got '\(rawValue)')")
        }
        return value
    }

    // MARK: set_keyframes

    private static let keyframePropertyNames: Set<String> = ["volumeDb", "opacity", "rotation", "position", "scale", "crop"]

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

        let applyKeyframes: () -> Void
        switch input.property {
        case "volumeDb":
            let kfs = try Self.parseScalarKeyframes(
                rows,
                path: "keyframes",
                valueName: "decibels",
                range: VolumeScale.floorDb...VolumeScale.ceilingDb
            )
            applyKeyframes = {
                editor.commitClipProperty(clipId: input.clipId) { $0.volumeTrack = kfs.keyframes.isEmpty ? nil : kfs }
            }
        case "opacity":
            let kfs = try Self.parseScalarKeyframes(rows, path: "keyframes", range: 0...1)
            applyKeyframes = {
                editor.commitClipProperty(clipId: input.clipId) { $0.opacityTrack = kfs.keyframes.isEmpty ? nil : kfs }
            }
        case "rotation":
            let kfs = try Self.parseScalarKeyframes(rows, path: "keyframes")
            applyKeyframes = {
                editor.commitClipProperty(clipId: input.clipId) { $0.rotationTrack = kfs.keyframes.isEmpty ? nil : kfs }
            }
        case "position":
            let kfs = try Self.parsePairKeyframes(rows, path: "keyframes")
            applyKeyframes = {
                editor.commitClipProperty(clipId: input.clipId) { $0.positionTrack = kfs.keyframes.isEmpty ? nil : kfs }
            }
        case "scale":
            let kfs = try Self.parsePairKeyframes(rows, path: "keyframes")
            applyKeyframes = {
                editor.commitClipProperty(clipId: input.clipId) { $0.scaleTrack = kfs.keyframes.isEmpty ? nil : kfs }
            }
        case "crop":
            let kfs = try Self.parseCropKeyframes(rows, path: "keyframes")
            applyKeyframes = {
                editor.commitClipProperty(clipId: input.clipId) { $0.cropTrack = kfs.keyframes.isEmpty ? nil : kfs }
            }
        default:
            throw ToolError("Unknown property '\(input.property)'")
        }

        let snapshot = timelineSnapshot(editor)
        editor.undo.perform("Set Keyframes (Agent)") {
            applyKeyframes()
        }

        let notes = rows.isEmpty ? ["Cleared \(input.property) keyframes."] : []
        return mutationResult(editor, since: snapshot, touched: [input.clipId], notes: notes)
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
        let snapshot = timelineSnapshot(editor)
        editor.undo.perform(points.count == 1 ? "Split Clip (Agent)" : "Split Clips (Agent)") {
            _ = editor.splitClips(at: points)
        }
        return mutationResult(editor, since: snapshot)
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
        let snapshot = timelineSnapshot(editor)
        let outcome = editor.undo.perform("Ripple Delete (Agent)") {
            editor.rippleDeleteRangesOnTrack(trackIndex: resolvedTrackIndex, ranges: frameRanges, ignoreSyncLockTrackIndices: ignoreSyncLocked)
        }
        switch outcome {
        case .refused(let reason):
            throw ToolError(reason)
        case .ok(let report):
            var extra: [String: Any] = ["removedFrames": report.removedFrames]
            if dropped > 0 { extra["rangesIgnored"] = dropped }
            return mutationResult(
                editor, since: snapshot,
                touched: report.resultingFragments.map(\.clipId),
                extra: extra
            )
        }
    }

    // MARK: - Keyframe row parsing (shared by set_keyframes)

    /// Parse `[[frame, value0, value1, ..., interp?], ...]` into a keyframe track.
    private static func parseKeyframes<V>(
        _ rows: [Any],
        path: String,
        fieldNames: [String],
        validateValues: (Int, [Double]) throws -> Void = { _, _ in },
        build: ([Double]) -> V
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
            try validateValues(i, values)
            let interp = try kfInterp(row.count > minLen ? row[minLen] : nil, at: "\(path)[\(i)][\(minLen)] (interp)")
            out.append(Keyframe(frame: frame, value: build(values), interpolationOut: interp))
        }
        return KeyframeTrack(keyframes: sortAndDedupe(out))
    }

    fileprivate static func parseScalarKeyframes(
        _ rows: [Any],
        path: String,
        valueName: String = "value",
        range: ClosedRange<Double>? = nil
    ) throws -> KeyframeTrack<Double> {
        try parseKeyframes(
            rows,
            path: path,
            fieldNames: [valueName],
            validateValues: { index, values in
                guard let range, !range.contains(values[0]) else { return }
                throw ToolError(
                    "\(path)[\(index)][1] (\(valueName)): must be between \(range.lowerBound) and \(range.upperBound) (got \(values[0]))"
                )
            }
        ) {
            $0[0]
        }
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
        guard !isJSONBoolean(raw) else { throw ToolError("\(path): expected integer") }
        if let v = raw as? Int { return v }
        if let v = raw as? Double, let i = safeInt(v) { return i }
        if let v = raw as? NSNumber, let i = safeInt(v.doubleValue) { return i }
        throw ToolError("\(path): expected integer")
    }

    private static func kfDouble(_ raw: Any, at path: String) throws -> Double {
        guard !isJSONBoolean(raw) else { throw ToolError("\(path): expected number") }
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

    // MARK: manage_tracks

    private static func exactTrackIndex(_ raw: Any?) -> Int? {
        guard let raw, !isJSONBoolean(raw),
              let value = (raw as? NSNumber)?.doubleValue, value.rounded() == value else { return nil }
        return Int(exactly: value)
    }

    func manageTracks(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["reorder", "set", "remove"], path: "manage_tracks")
        let tracks = editor.timeline.tracks

        func trackId(_ index: Int, _ path: String) throws -> String {
            guard tracks.indices.contains(index) else {
                throw ToolError("\(path): track index \(index) out of range (timeline has \(tracks.count) tracks)")
            }
            return tracks[index].id
        }

        func trackId(_ entry: [String: Any], _ path: String) throws -> String {
            if let id = entry["trackId"] as? String {
                guard entry["index"] == nil, tracks.contains(where: { $0.id == id }) else {
                    throw ToolError("\(path): pass one current trackId or index")
                }
                return id
            }
            guard entry["trackId"] == nil, let index = Self.exactTrackIndex(entry["index"]) else {
                throw ToolError("\(path): pass one current trackId or index")
            }
            return try trackId(index, path)
        }

        var reorders: [(id: String, to: Int)] = []
        for (i, raw) in (args["reorder"] as? [Any] ?? []).enumerated() {
            guard let entry = raw as? [String: Any] else { throw ToolError("reorder[\(i)] must be an object") }
            let path = "reorder[\(i)]"
            try validateUnknownKeys(entry, allowed: ["trackId", "index", "to"], path: path)
            guard let to = Self.exactTrackIndex(entry["to"]) else {
                throw ToolError("\(path): 'to' is required and must be an integer")
            }
            let id = try trackId(entry, path)
            guard let from = tracks.firstIndex(where: { $0.id == id }),
                  tracks.indices.contains(to), tracks[from].type == tracks[to].type else {
                throw ToolError("\(path): destination index \(to) is outside the track's type zone")
            }
            reorders.append((id, to))
        }

        var flagSets: [(id: String, muted: Bool?, hidden: Bool?, syncLocked: Bool?)] = []
        for (i, raw) in (args["set"] as? [Any] ?? []).enumerated() {
            guard let entry = raw as? [String: Any] else { throw ToolError("set[\(i)] must be an object") }
            let path = "set[\(i)]"
            try validateUnknownKeys(entry, allowed: ["trackId", "index", "muted", "hidden", "syncLocked"], path: path)
            let muted = entry["muted"] as? Bool
            let hidden = entry["hidden"] as? Bool
            let syncLocked = entry["syncLocked"] as? Bool
            guard muted != nil || hidden != nil || syncLocked != nil else {
                throw ToolError("\(path): pass at least one of muted, hidden, syncLocked")
            }
            flagSets.append((try trackId(entry, path), muted, hidden, syncLocked))
        }

        var removeIds: [String] = []
        for (i, raw) in (args["remove"] as? [Any] ?? []).enumerated() {
            let path = "remove[\(i)]"
            if let entry = raw as? [String: Any] {
                try validateUnknownKeys(entry, allowed: ["trackId", "index"], path: path)
                removeIds.append(try trackId(entry, path))
                continue
            }
            guard let index = Self.exactTrackIndex(raw) else {
                throw ToolError("\(path) must be an integer index or track selector object")
            }
            removeIds.append(try trackId(index, path))
        }

        guard !reorders.isEmpty || !flagSets.isEmpty || !removeIds.isEmpty else {
            throw ToolError("Nothing to do — pass at least one of reorder, set, remove.")
        }

        let multicamTrackIds = Set(tracks.filter { t in
            t.clips.contains { $0.multicamGroupId != nil }
        }.map(\.id))
        if removeIds.contains(where: { multicamTrackIds.contains($0) }) {
            throw ToolError("A multicam group's track can't be removed — delete the group's clips first (remove_clips) and the empty track prunes itself.")
        }
        if flagSets.contains(where: { multicamTrackIds.contains($0.id) && $0.syncLocked == false }) {
            throw ToolError("Sync lock stays on for a multicam group's tracks — unlocking would let ripples shift the group's members apart.")
        }

        let snapshot = timelineSnapshot(editor)
        let removeIdSet = Set(removeIds)
        let removedTracks = tracks.indices.compactMap { i -> [String: Any]? in
            let track = tracks[i]
            guard removeIdSet.contains(track.id) else { return nil }
            return ["trackId": track.id, "index": i, "label": editor.timelineTrackDisplayLabel(at: i), "type": track.type.rawValue]
        }
        var reorderResults: [(trackId: String, from: Int, to: Int)] = []
        editor.undo.perform("Manage Tracks (Agent)") {
            if !reorders.isEmpty {
                let before = editor.timeline
                for r in reorders {
                    guard let from = editor.timeline.tracks.firstIndex(where: { $0.id == r.id }) else { continue }
                    editor.reorderTrackLive(id: r.id, to: r.to)
                    let destination = editor.timeline.tracks.firstIndex(where: { $0.id == r.id }) ?? from
                    reorderResults.append((r.id, from, destination))
                }
                editor.commitTrackReorder(before: before)
            }
            for f in flagSets {
                guard let idx = editor.timeline.tracks.firstIndex(where: { $0.id == f.id }) else { continue }
                let track = editor.timeline.tracks[idx]
                if let m = f.muted, track.muted != m { editor.toggleTrackMute(trackIndex: idx) }
                if let h = f.hidden, track.hidden != h { editor.toggleTrackHidden(trackIndex: idx) }
                if let s = f.syncLocked, track.syncLocked != s { editor.toggleTrackSyncLock(trackIndex: idx) }
            }
            if !removeIds.isEmpty { editor.removeTracks(ids: removeIds) }
        }

        let order = editor.timeline.tracks.indices.map { i -> [String: Any] in
            let track = editor.timeline.tracks[i]
            var entry: [String: Any] = ["trackId": track.id, "index": i, "label": editor.timelineTrackDisplayLabel(at: i), "type": track.type.rawValue]
            if track.muted { entry["muted"] = true }
            if track.hidden { entry["hidden"] = true }
            if !track.syncLocked { entry["syncLocked"] = false }
            return entry
        }
        var extra: [String: Any] = ["tracks": order]
        if !reorderResults.isEmpty {
            extra["reordered"] = reorderResults.map { ["trackId": $0.trackId, "from": $0.from, "to": $0.to, "changed": $0.from != $0.to] }
        }
        if !removedTracks.isEmpty { extra["removedTracks"] = removedTracks }
        return mutationResult(editor, since: snapshot, extra: extra)
    }
}
