import Foundation

fileprivate struct ApplyLayoutInput: DecodableToolArgs {
    struct SlotEntry: Decodable {
        let slot: String
        let mediaRef: String?
        let clipIds: [String]?
        let anchor: String?
        let anchorX: Double?
        let anchorY: Double?
        static let allowedKeys: Set<String> = ["slot", "mediaRef", "clipIds", "anchor", "anchorX", "anchorY"]
    }
    let layout: String
    let slots: [SlotEntry]
    let startFrame: Int?
    let endFrame: Int?
    let fit: String?
    static let allowedKeys: Set<String> = ["layout", "slots", "startFrame", "endFrame", "fit"]
}

extension ToolExecutor {

    static let layoutAnchors: [String: (x: Double, y: Double)] = [
        "center": (0.5, 0.5),
        "top": (0.5, 0), "bottom": (0.5, 1), "left": (0, 0.5), "right": (1, 0.5),
        "top_left": (0, 0), "top_right": (1, 0), "bottom_left": (0, 1), "bottom_right": (1, 1),
    ]

    private func resolveAnchor(_ e: ApplyLayoutInput.SlotEntry, path: String) throws -> (x: Double, y: Double) {
        var anchor = Self.layoutAnchors["center"]!
        if let raw = e.anchor {
            guard let a = Self.layoutAnchors[raw] else {
                throw ToolError("\(path): invalid anchor '\(raw)'. Valid: \(Self.layoutAnchors.keys.sorted().joined(separator: ", ")), or anchorX/anchorY for in-between values.")
            }
            anchor = a
        }
        for (axis, v) in [("anchorX", e.anchorX), ("anchorY", e.anchorY)] where v != nil {
            guard (0...1).contains(v!) else { throw ToolError("\(path): \(axis) must be between 0 and 1 (got \(v!))") }
        }
        if let ax = e.anchorX { anchor.x = ax }
        if let ay = e.anchorY { anchor.y = ay }
        return anchor
    }

    func applyLayout(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try editor.undo.perform("Apply Layout (Agent)") {
            try applyLayoutMutation(editor, args)
        }
    }

    private func applyLayoutMutation(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: ApplyLayoutInput = try decodeToolArgs(args, path: "apply_layout")
        for (i, raw) in (args["slots"] as? [Any] ?? []).enumerated() {
            if let d = raw as? [String: Any] {
                try validateUnknownKeys(d, allowed: ApplyLayoutInput.SlotEntry.allowedKeys, path: "slots[\(i)]")
            }
        }
        guard let layout = VideoLayout(rawValue: input.layout) else {
            throw ToolError("unknown layout '\(input.layout)'. Valid: \(VideoLayout.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let fit = LayoutFit(rawValue: input.fit ?? "fill") else {
            throw ToolError("invalid fit '\(input.fit ?? "")'. Valid: fill, fit")
        }
        guard !input.slots.isEmpty else { throw ToolError("apply_layout needs a non-empty 'slots' array") }

        let slotById = Dictionary(uniqueKeysWithValues: layout.slots.map { ($0.id, $0) })

        var seen = Set<String>()
        var seenClips = Set<String>()
        var usesMedia = false, usesClip = false
        var entries: [(slot: LayoutSlot, entry: ApplyLayoutInput.SlotEntry, anchor: (x: Double, y: Double))] = []
        for (i, e) in input.slots.enumerated() {
            guard let slot = slotById[e.slot] else {
                throw ToolError("slots[\(i)]: '\(e.slot)' is not a slot of layout '\(layout.rawValue)'. Slots: \(layout.slots.map(\.id).joined(separator: ", "))")
            }
            guard seen.insert(e.slot).inserted else { throw ToolError("slots[\(i)]: duplicate slot '\(e.slot)'") }
            guard (e.mediaRef != nil) != (e.clipIds != nil) else {
                throw ToolError("slots[\(i)]: provide exactly one of 'mediaRef' or 'clipIds'")
            }
            if let cids = e.clipIds {
                guard !cids.isEmpty else { throw ToolError("slots[\(i)]: 'clipIds' must not be empty") }
                for cid in cids where !seenClips.insert(cid).inserted {
                    throw ToolError("slots[\(i)]: clip '\(cid)' is assigned to more than one slot; each clip can fill only one.")
                }
            }
            usesMedia = usesMedia || e.mediaRef != nil
            usesClip = usesClip || e.clipIds != nil
            entries.append((slot, e, try resolveAnchor(e, path: "slots[\(i)]")))
        }
        let missing = Set(slotById.keys).subtracting(seen)
        guard missing.isEmpty else {
            throw ToolError("layout '\(layout.rawValue)' needs every slot filled. Missing: \(missing.sorted().joined(separator: ", "))")
        }
        guard !(usesMedia && usesClip) else {
            throw ToolError("apply_layout: don't mix 'mediaRef' and 'clipIds' — either place new clips (all mediaRef) or re-layout existing clips (all clipIds).")
        }

        let startFrame = input.startFrame ?? 0
        let duration = input.endFrame.map { $0 - (input.startFrame ?? 0) } ?? 0
        var assetBySlot: [String: MediaAsset] = [:]
        var settingsNote: String?
        if usesMedia {
            guard startFrame >= 0 else { throw ToolError("startFrame must be >= 0 (got \(startFrame))") }
            guard duration >= 1 else { throw ToolError("apply_layout placing new clips requires endFrame > startFrame.") }
            for e in entries {
                let a = try asset(e.entry.mediaRef!, editor: editor)
                guard a.type == .video || a.type == .image else {
                    throw ToolError("slot '\(e.slot.id)': asset \(e.entry.mediaRef!) is \(a.type.rawValue); layout slots take video or image.")
                }
                assetBySlot[e.slot.id] = a
            }
            settingsNote = applySettingsIfNeededForAgent(
                editor,
                assets: layout.slots.compactMap { assetBySlot[$0.id] }
            )
        } else {
            var rangesByTrack: [String: [(slot: String, start: Int, end: Int)]] = [:]
            var intervalsBySlot: [String: [(start: Int, end: Int)]] = [:]
            for e in entries {
                for cid in e.entry.clipIds! {
                    guard let loc = editor.findClip(id: cid) else { throw ToolError("slot '\(e.slot.id)': clip not found: \(cid)") }
                    let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
                    guard clip.mediaType == .video || clip.mediaType == .image else {
                        throw ToolError("slot '\(e.slot.id)': clip \(cid) is \(clip.mediaType.rawValue); layout applies to video/image clips.")
                    }
                    let trackId = editor.timeline.tracks[loc.trackIndex].id
                    let start = clip.startFrame, end = clip.startFrame + clip.durationFrames
                    for other in rangesByTrack[trackId] ?? [] where other.slot != e.slot.id && start < other.end && other.start < end {
                        throw ToolError("clips in slots '\(other.slot)' and '\(e.slot.id)' are on the same track and their times overlap; only the first would render. Move them to separate tracks (or place new clips with mediaRef) so every region shows.")
                    }
                    rangesByTrack[trackId, default: []].append((e.slot.id, start, end))
                    intervalsBySlot[e.slot.id, default: []].append((start, end))
                }
            }
            if entries.count > 1 {
                let candidates = intervalsBySlot.values.flatMap { $0.map(\.start) }
                let coincides = candidates.contains { f in
                    intervalsBySlot.values.allSatisfy { ivs in ivs.contains { $0.start <= f && f < $0.end } }
                }
                guard coincides else {
                    throw ToolError("the selected clips never play at the same time, so no single frame shows every region. Overlap their timeline ranges (or place new clips with mediaRef) before laying them out.")
                }
            }
        }

        let snapshot = timelineSnapshot(editor)
        var slots: [String: [String]] = [:]

        editor.withTimelineSwap(actionName: "Apply Layout (Agent)") {
            var clipsBySlot: [String: [String]] = [:]
            if usesMedia {
                var trackBySlot: [String: String] = [:]
                for slot in layout.slots.sorted(by: { $0.z < $1.z }) {
                    let idx = editor.insertTrack(at: 0, type: .video)
                    trackBySlot[slot.id] = editor.timeline.tracks[idx].id
                }
                for e in entries {
                    guard let tid = trackBySlot[e.slot.id], let asset = assetBySlot[e.slot.id],
                          let tIdx = editor.timeline.tracks.firstIndex(where: { $0.id == tid }) else { continue }
                    let ids = editor.placeClip(asset: asset, trackIndex: tIdx, startFrame: startFrame, durationFrames: duration)
                    if let primary = ids.first { clipsBySlot[e.slot.id] = [primary] }
                }
            } else {
                for e in entries {
                    clipsBySlot[e.slot.id] = e.entry.clipIds!
                }
            }

            for e in entries {
                for cid in clipsBySlot[e.slot.id] ?? [] {
                    guard let clip = editor.clipFor(id: cid), let loc = editor.findClip(id: cid) else { continue }
                    let p = editor.layoutPlacement(for: clip, in: e.slot.rect, fit: fit, anchorX: e.anchor.x, anchorY: e.anchor.y)
                    editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].transform = p.transform
                    editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].crop = p.crop
                    editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].positionTrack = nil
                    editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].scaleTrack = nil
                    editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].rotationTrack = nil
                    editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].cropTrack = nil
                }
            }
            slots = clipsBySlot
        }

        guard !slots.isEmpty else { throw ToolError("apply_layout changed no clips.") }

        var notes = settingsNote.map { [$0] } ?? []
        if !usesMedia {
            notes.append("Stacking follows current track order (index 0 on top); fix with manage_tracks reorder if an inset isn't on top.")
        }
        return mutationResult(
            editor, since: snapshot,
            touched: slots.values.flatMap { $0 },
            extra: ["layout": layout.rawValue, "slots": slots],
            notes: notes
        )
    }
}
