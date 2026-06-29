import Foundation

fileprivate struct ApplyLayoutInput: DecodableToolArgs {
    struct SlotEntry: Decodable {
        let slot: String
        let mediaRef: String?
        let clipId: String?
        let anchor: String?
        let anchorX: Double?
        let anchorY: Double?
        static let allowedKeys: Set<String> = ["slot", "mediaRef", "clipId", "anchor", "anchorX", "anchorY"]
    }
    let layout: String
    let slots: [SlotEntry]
    let startFrame: Int?
    let durationFrames: Int?
    let fit: String?
    static let allowedKeys: Set<String> = ["layout", "slots", "startFrame", "durationFrames", "fit"]
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
            guard (e.mediaRef != nil) != (e.clipId != nil) else {
                throw ToolError("slots[\(i)]: provide exactly one of 'mediaRef' or 'clipId'")
            }
            if let cid = e.clipId, !seenClips.insert(cid).inserted {
                throw ToolError("slots[\(i)]: clip '\(cid)' is assigned to more than one slot; each clip can fill only one.")
            }
            usesMedia = usesMedia || e.mediaRef != nil
            usesClip = usesClip || e.clipId != nil
            entries.append((slot, e, try resolveAnchor(e, path: "slots[\(i)]")))
        }
        let missing = Set(slotById.keys).subtracting(seen)
        guard missing.isEmpty else {
            throw ToolError("layout '\(layout.rawValue)' needs every slot filled. Missing: \(missing.sorted().joined(separator: ", "))")
        }
        guard !(usesMedia && usesClip) else {
            throw ToolError("apply_layout: don't mix 'mediaRef' and 'clipId' — either place new clips (all mediaRef) or re-layout existing clips (all clipId).")
        }

        let startFrame = input.startFrame ?? 0
        let duration = input.durationFrames ?? 0
        var assetBySlot: [String: MediaAsset] = [:]
        var settingsNote: String?
        if usesMedia {
            guard startFrame >= 0 else { throw ToolError("startFrame must be >= 0 (got \(startFrame))") }
            guard duration >= 1 else { throw ToolError("apply_layout placing new clips requires durationFrames >= 1.") }
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
            var commonStart = Int.min, commonEnd = Int.max
            for e in entries {
                guard let loc = editor.findClip(id: e.entry.clipId!) else { throw ToolError("slot '\(e.slot.id)': clip not found: \(e.entry.clipId!)") }
                let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
                guard clip.mediaType == .video || clip.mediaType == .image else {
                    throw ToolError("slot '\(e.slot.id)': clip \(e.entry.clipId!) is \(clip.mediaType.rawValue); layout applies to video/image clips.")
                }
                let trackId = editor.timeline.tracks[loc.trackIndex].id
                let start = clip.startFrame, end = clip.startFrame + clip.durationFrames
                for other in rangesByTrack[trackId] ?? [] where start < other.end && other.start < end {
                    throw ToolError("slots '\(other.slot)' and '\(e.slot.id)' are clips on the same track whose times overlap; only the first would render. Move them to separate tracks (or place new clips with mediaRef) so every region shows.")
                }
                rangesByTrack[trackId, default: []].append((e.slot.id, start, end))
                commonStart = max(commonStart, start); commonEnd = min(commonEnd, end)
            }
            if entries.count > 1, commonStart >= commonEnd {
                throw ToolError("the selected clips never play at the same time, so no single frame shows every region. Overlap their timeline ranges (or place new clips with mediaRef) before laying them out.")
            }
        }

        let tracksBefore = Set(editor.timeline.tracks.map(\.id))
        var summaries: [String] = []

        editor.withTimelineSwap(actionName: "Apply Layout (Agent)") {
            var clipBySlot: [String: String] = [:]
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
                    if let primary = ids.first {
                        clipBySlot[e.slot.id] = primary
                        summaries.append("\(e.slot.id) → \(primary)\(ids.count > 1 ? " (+audio \(ids[1]))" : "")")
                    }
                }
            } else {
                for e in entries {
                    clipBySlot[e.slot.id] = e.entry.clipId!
                    summaries.append("\(e.slot.id) → \(e.entry.clipId!)")
                }
            }

            for e in entries {
                guard let cid = clipBySlot[e.slot.id], let clip = editor.clipFor(id: cid),
                      let loc = editor.findClip(id: cid) else { continue }
                let p = editor.layoutPlacement(for: clip, in: e.slot.rect, fit: fit, anchorX: e.anchor.x, anchorY: e.anchor.y)
                editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].transform = p.transform
                editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].crop = p.crop
                editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].positionTrack = nil
                editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].scaleTrack = nil
                editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].rotationTrack = nil
                editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].cropTrack = nil
            }
        }

        guard !summaries.isEmpty else { throw ToolError("apply_layout changed no clips.") }

        var prefix = settingsNote.map { "\($0) " } ?? ""
        let createdTracks = editor.timeline.tracks.enumerated()
            .filter { !tracksBefore.contains($0.element.id) }
            .map { "track \($0.offset) ('\(editor.timelineTrackDisplayLabel(at: $0.offset))', \($0.element.type.rawValue))" }
        if !createdTracks.isEmpty { prefix += "Created \(createdTracks.joined(separator: ", ")). " }
        let span = usesMedia ? " at frame \(startFrame) for \(duration)" : " on existing clips"
        let tail = usesMedia ? "" : " Stacking follows current track order; reorder tracks if a PIP inset isn't on top."
        return .ok("\(prefix)Applied '\(layout.rawValue)' layout (\(fit.rawValue))\(span): \(summaries.joined(separator: "; ")).\(tail)")
    }
}
