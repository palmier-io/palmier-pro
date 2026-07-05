import Foundation

// MARK: - Input shapes

fileprivate struct CreateMulticamInput: DecodableToolArgs {
    let name: String?
    let members: [Member]
    let referenceMediaRef: String?
    let sync: Bool?
    let searchWindowSeconds: Double?
    let minConfidence: Double?
    let layout: Bool?
    let startFrame: Int?
    static let allowedKeys: Set<String> = [
        "name", "members", "referenceMediaRef", "sync",
        "searchWindowSeconds", "minConfidence", "layout", "startFrame",
    ]

    struct Member: DecodableToolArgs {
        let mediaRef: String
        let role: String
        let speaker: String?
        let syncOffsetFrames: Int?
        static let allowedKeys: Set<String> = ["mediaRef", "role", "speaker", "syncOffsetFrames"]
    }
}

fileprivate struct SpeakerActivityInput: DecodableToolArgs {
    let groupId: String?
    let startFrame: Int?
    let endFrame: Int?
    let minTurnFrames: Int?
    let bridgeGapFrames: Int?
    static let allowedKeys: Set<String> = ["groupId", "startFrame", "endFrame", "minTurnFrames", "bridgeGapFrames"]
}

fileprivate struct SwitchAngleInput: DecodableToolArgs {
    let trackIndex: Int
    let switches: [Switch]
    static let allowedKeys: Set<String> = ["trackIndex", "switches"]

    struct Switch: DecodableToolArgs {
        let startFrame: Int
        let endFrame: Int
        let mediaRef: String?
        let layout: String?
        let slots: [Slot]?
        let fit: String?
        static let allowedKeys: Set<String> = ["startFrame", "endFrame", "mediaRef", "layout", "slots", "fit"]
    }

    struct Slot: DecodableToolArgs {
        let slot: String
        let mediaRef: String
        static let allowedKeys: Set<String> = ["slot", "mediaRef"]
    }
}

fileprivate struct RemoveMulticamInput: DecodableToolArgs {
    let groupId: String?
    static let allowedKeys: Set<String> = ["groupId"]
}

fileprivate struct JoinClipsInput: DecodableToolArgs {
    let trackIndex: Int?
    let startFrame: Int?
    let endFrame: Int?
    static let allowedKeys: Set<String> = ["trackIndex", "startFrame", "endFrame"]
}

fileprivate struct SetMulticamSpeakersInput: DecodableToolArgs {
    let groupId: String
    let speakers: [Entry]
    static let allowedKeys: Set<String> = ["groupId", "speakers"]

    struct Entry: DecodableToolArgs {
        let mediaRef: String
        let speaker: String?
        static let allowedKeys: Set<String> = ["mediaRef", "speaker"]
    }
}

// MARK: - Handlers

extension ToolExecutor {

    // MARK: create_multicam

    func createMulticam(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: CreateMulticamInput = try decodeToolArgs(args, path: "create_multicam")
        if let raws = args["members"] as? [Any] {
            for (idx, raw) in raws.enumerated() {
                if let d = raw as? [String: Any] {
                    try validateUnknownKeys(d, allowed: CreateMulticamInput.Member.allowedKeys, path: "members[\(idx)]")
                }
            }
        }
        guard input.members.count >= 2 else {
            throw ToolError("create_multicam needs at least 2 members (cameras and/or mics).")
        }

        var members: [MulticamGroup.Member] = []
        for (idx, m) in input.members.enumerated() {
            let asset = try asset(m.mediaRef, editor: editor)
            guard let role = MulticamGroup.Role(rawValue: m.role) else {
                throw ToolError("members[\(idx)]: role must be 'camera', 'mic', or 'both' (got '\(m.role)')")
            }
            switch role {
            case .camera:
                guard asset.type == .video else {
                    throw ToolError("members[\(idx)]: camera members must be video assets (\(asset.id) is \(asset.type.rawValue))")
                }
            case .mic:
                guard asset.type == .audio || (asset.type == .video && asset.hasAudio) else {
                    throw ToolError("members[\(idx)]: mic member \(asset.id) has no audio")
                }
            case .both:
                guard asset.type == .video && asset.hasAudio else {
                    throw ToolError("members[\(idx)]: 'both' members must be video assets with audio (\(asset.id) is \(asset.type.rawValue)\(asset.type == .video ? ", no audio" : ""))")
                }
            }
            if members.contains(where: { $0.mediaRef == asset.id }) {
                throw ToolError("members[\(idx)]: duplicate mediaRef \(asset.id)")
            }
            members.append(MulticamGroup.Member(
                mediaRef: asset.id, role: role,
                syncOffsetFrames: m.syncOffsetFrames ?? 0, speaker: m.speaker
            ))
        }

        // Sync any member without an explicit offset against the reference.
        let needsSync = input.sync ?? true
        let explicitOffsets = Set(input.members.enumerated()
            .filter { $0.element.syncOffsetFrames != nil }
            .map { members[$0.offset].mediaRef })
        var confidences: [String: Double] = [:]
        var syncFailures: [[String: Any]] = []
        if needsSync {
            let referenceRef: String
            if let explicit = input.referenceMediaRef {
                guard members.contains(where: { $0.mediaRef == explicit }) else {
                    throw ToolError("referenceMediaRef \(explicit) is not one of the members")
                }
                referenceRef = explicit
            } else {
                referenceRef = (members.first { $0.role.isMic } ?? members[0]).mediaRef
            }
            let toSync = members.map(\.mediaRef).filter { !explicitOffsets.contains($0) && $0 != referenceRef }
            if !toSync.isEmpty {
                let report = await editor.computeMulticamOffsets(
                    memberRefs: toSync,
                    referenceRef: referenceRef,
                    searchWindowSeconds: input.searchWindowSeconds ?? EditorViewModel.AudioSyncDefaults.searchWindowSeconds,
                    minConfidence: input.minConfidence ?? EditorViewModel.AudioSyncDefaults.minConfidence
                )
                for i in members.indices where !explicitOffsets.contains(members[i].mediaRef) {
                    if let offset = report.offsets[members[i].mediaRef] {
                        members[i].syncOffsetFrames = offset
                    }
                }
                confidences = report.confidences
                syncFailures = report.failures.map { ["mediaRef": $0.mediaRef, "reason": $0.message] }
            }
        }

        var group = MulticamGroup(
            name: input.name ?? "Multicam \(editor.multicamGroups.count + 1)",
            members: members
        )

        var layoutResult: EditorViewModel.MulticamLayoutResult?
        withUndoGroup(editor, actionName: "Create Multicam Group") {
            group = editor.upsertMulticamGroup(group)
            if input.layout ?? true {
                layoutResult = editor.layoutMulticamGroup(group, startFrame: max(0, input.startFrame ?? 0))
            }
        }

        var payload: [String: Any] = [
            "groupId": group.id,
            "name": group.name,
            "members": group.members.map { m -> [String: Any] in
                var row: [String: Any] = [
                    "mediaRef": m.mediaRef,
                    "role": m.role.rawValue,
                    "syncOffsetFrames": m.syncOffsetFrames,
                ]
                if let s = m.speaker { row["speaker"] = s }
                if let c = confidences[m.mediaRef] { row["syncConfidence"] = (c * 1000).rounded() / 1000 }
                return row
            },
        ]
        if let layoutResult {
            payload["programTrackIndex"] = layoutResult.programTrackIndex
            payload["placedClipIds"] = layoutResult.placedClipIds
            if !layoutResult.skipped.isEmpty {
                payload["layoutSkipped"] = layoutResult.skipped.map { ["mediaRef": $0.mediaRef, "reason": $0.message] }
            }
        }
        if !syncFailures.isEmpty { payload["syncFailures"] = syncFailures }
        guard let json = Self.jsonString(payload) else { throw ToolError("Failed to encode result") }
        return .ok(json)
    }

    // MARK: get_speaker_activity

    private static let speakerSegmentCap = 2000

    func getSpeakerActivity(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: SpeakerActivityInput = try decodeToolArgs(args, path: "get_speaker_activity")
        let group = try resolveMulticamGroup(input.groupId, editor: editor)
        guard !group.mics.isEmpty else {
            throw ToolError("Group '\(group.name)' has no mic members — speaker activity needs per-speaker mics. For a single mixed recording, use get_transcript instead: cloud transcription returns speaker labels via diarization.")
        }
        if let s = input.startFrame, let e = input.endFrame, s >= e {
            throw ToolError("startFrame (\(s)) must be less than endFrame (\(e))")
        }
        let window: Range<Int>? = (input.startFrame != nil || input.endFrame != nil)
            ? (input.startFrame ?? 0)..<(input.endFrame ?? Int.max)
            : nil

        let (mics, missing) = await editor.speakerActivityTracks(group: group, window: window)
        guard !mics.isEmpty else {
            throw ToolError("No mic clips of group '\(group.name)' are on the timeline. Lay the group out first (create_multicam with layout, or add_clips).")
        }

        var options = SpeakerActivity.Options()
        if let v = input.minTurnFrames { options.minTurnFrames = max(0, v) }
        if let v = input.bridgeGapFrames { options.bridgeGapFrames = max(0, v) }
        var segments = SpeakerActivity.segments(mics: mics, fps: editor.timeline.fps, options: options)
        if let window {
            segments = segments.filter { $0.endFrame > window.lowerBound && $0.startFrame < window.upperBound }
        }

        var payload: [String: Any] = [
            "groupId": group.id,
            "fps": editor.timeline.fps,
            "timing": "projectFrames",
            "segmentFormat": ["speaker", "startFrame", "endFrame", "confidence"],
            "segments": segments.prefix(Self.speakerSegmentCap).map { seg -> [Any] in
                [seg.speaker, seg.startFrame, seg.endFrame, seg.confidence]
            },
            "angles": group.cameras.map { cam -> [String: Any] in
                var row: [String: Any] = ["mediaRef": cam.mediaRef]
                if let s = cam.speaker { row["speaker"] = s }
                return row
            },
        ]
        if segments.count > Self.speakerSegmentCap {
            payload["totalSegments"] = segments.count
            if let lastShown = segments.prefix(Self.speakerSegmentCap).last {
                payload["nextStartFrame"] = lastShown.endFrame
                payload["segmentsNote"] = "First \(Self.speakerSegmentCap) of \(segments.count) segments. Continue with startFrame = nextStartFrame, or raise minTurnFrames/bridgeGapFrames."
            }
        }
        if !missing.isEmpty { payload["micsWithoutClips"] = missing }
        guard let json = Self.jsonString(payload) else { throw ToolError("Failed to encode result") }
        return .ok(json)
    }

    // MARK: switch_angle

    func switchAngle(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: SwitchAngleInput = try decodeToolArgs(args, path: "switch_angle")
        if let raws = args["switches"] as? [Any] {
            for (idx, raw) in raws.enumerated() {
                if let d = raw as? [String: Any] {
                    try validateUnknownKeys(d, allowed: SwitchAngleInput.Switch.allowedKeys, path: "switches[\(idx)]")
                }
            }
        }
        guard !input.switches.isEmpty else { throw ToolError("Missing or empty 'switches' array") }
        guard editor.timeline.tracks.indices.contains(input.trackIndex) else {
            throw ToolError("trackIndex \(input.trackIndex) out of range (0..\(editor.timeline.tracks.count - 1))")
        }
        guard editor.timeline.tracks[input.trackIndex].type != .audio else {
            throw ToolError("trackIndex \(input.trackIndex) is an audio track — switch_angle operates on the program video track.")
        }
        var requests: [EditorViewModel.AngleSwitchRequest] = []
        for (idx, s) in input.switches.enumerated() {
            let path = "switches[\(idx)]"
            guard s.endFrame > s.startFrame, s.startFrame >= 0 else {
                throw ToolError("\(path): endFrame must be greater than startFrame (got [\(s.startFrame), \(s.endFrame)))")
            }
            guard (s.mediaRef != nil) != (s.layout != nil) else {
                throw ToolError("\(path): provide exactly one of 'mediaRef' (single full-frame angle) or 'layout'+'slots' (multi-angle layout).")
            }
            let fit = try s.fit.map {
                guard let f = LayoutFit(rawValue: $0) else { throw ToolError("\(path): invalid fit '\($0)'. Valid: fill, fit") }
                return f
            } ?? LayoutFit.fill

            var layout = VideoLayout.full
            var assignments: [(slotId: String, mediaRef: String)] = []
            if let single = s.mediaRef {
                let asset = try asset(single, editor: editor)
                assignments = [("main", asset.id)]
            } else {
                guard let l = VideoLayout(rawValue: s.layout!) else {
                    throw ToolError("\(path): unknown layout '\(s.layout!)'. Valid: \(VideoLayout.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                guard l != .full else {
                    throw ToolError("\(path): layout 'full' is the single-angle case — pass 'mediaRef' instead.")
                }
                layout = l
                guard let slots = s.slots, !slots.isEmpty else {
                    throw ToolError("\(path): 'layout' requires a 'slots' array of {slot, mediaRef}.")
                }
                let slotIds = l.slots.map(\.id)
                var seen = Set<String>()
                for entry in slots {
                    guard slotIds.contains(entry.slot) else {
                        throw ToolError("\(path): '\(entry.slot)' is not a slot of layout '\(l.rawValue)'. Slots: \(slotIds.joined(separator: ", "))")
                    }
                    guard seen.insert(entry.slot).inserted else {
                        throw ToolError("\(path): duplicate slot '\(entry.slot)'")
                    }
                    let asset = try asset(entry.mediaRef, editor: editor)
                    assignments.append((entry.slot, asset.id))
                }
                let missing = Set(slotIds).subtracting(seen)
                guard missing.isEmpty else {
                    throw ToolError("\(path): layout '\(l.rawValue)' needs every slot filled. Missing: \(missing.sorted().joined(separator: ", "))")
                }
                // Program track shows the layout's first slot; keep declaration order stable.
                assignments.sort { a, b in
                    (slotIds.firstIndex(of: a.slotId) ?? 0) < (slotIds.firstIndex(of: b.slotId) ?? 0)
                }
            }
            for (_, ref) in assignments {
                guard editor.multicamGroup(containing: ref) != nil else {
                    throw ToolError("\(path): \(ref) is not a member of any multicam group. Create one with create_multicam first.")
                }
            }
            requests.append(EditorViewModel.AngleSwitchRequest(
                range: FrameRange(start: s.startFrame, end: s.endFrame),
                layout: layout, fit: fit, assignments: assignments
            ))
        }

        let outcome = withUndoGroup(editor, actionName: "Switch Angle (Agent)") {
            editor.switchAngle(trackIndex: input.trackIndex, requests: requests)
        }

        var payload: [String: Any] = [
            "switched": outcome.switchedClipIds.count,
            "splits": outcome.splitCount,
        ]
        if outcome.joinedSeams > 0 {
            payload["joinedSeams"] = outcome.joinedSeams
        }
        if !outcome.placedOverlayClipIds.isEmpty {
            payload["overlayClips"] = outcome.placedOverlayClipIds.count
        }
        if outcome.createdOverlayTracks > 0 {
            payload["createdOverlayTracks"] = outcome.createdOverlayTracks
            payload["note"] = "Overlay tracks were inserted above the program track — track indices shifted; the program track is now at a higher index."
        }
        if let minStart = requests.map(\.range.start).min(), let maxEnd = requests.map(\.range.end).max() {
            payload["rangeCovered"] = [minStart, maxEnd]
        }
        if !outcome.clamped.isEmpty {
            payload["clamped"] = outcome.clamped.map { c -> [String: Any] in
                [
                    "requested": [c.requested.start, c.requested.end],
                    "applied": [c.applied.start, c.applied.end],
                    "reason": c.message,
                ]
            }
        }
        if !outcome.skipped.isEmpty {
            payload["skipped"] = outcome.skipped.map { skip -> [String: Any] in
                ["range": [skip.range.start, skip.range.end], "reason": skip.message]
            }
        }
        guard let json = Self.jsonString(payload) else { throw ToolError("Failed to encode result") }
        if outcome.switchedClipIds.isEmpty && outcome.placedOverlayClipIds.isEmpty
            && outcome.splitCount == 0 && !outcome.skipped.isEmpty {
            return .error(json)
        }
        return .ok(json)
    }

    // MARK: set_multicam_speakers

    func setMulticamSpeakers(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: SetMulticamSpeakersInput = try decodeToolArgs(args, path: "set_multicam_speakers")
        if let raws = args["speakers"] as? [Any] {
            for (idx, raw) in raws.enumerated() {
                if let d = raw as? [String: Any] {
                    try validateUnknownKeys(d, allowed: SetMulticamSpeakersInput.Entry.allowedKeys, path: "speakers[\(idx)]")
                }
            }
        }
        guard !input.speakers.isEmpty else { throw ToolError("Missing or empty 'speakers' array") }
        guard var group = editor.multicamGroup(id: input.groupId) else {
            throw ToolError("Multicam group not found: \(input.groupId)")
        }
        for (idx, entry) in input.speakers.enumerated() {
            guard let memberIdx = group.members.firstIndex(where: { $0.mediaRef == entry.mediaRef }) else {
                throw ToolError("speakers[\(idx)]: \(entry.mediaRef) is not a member of group '\(group.name)'")
            }
            group.members[memberIdx].speaker = entry.speaker
        }
        withUndoGroup(editor, actionName: "Set Multicam Speakers") {
            editor.updateMulticamGroup(group)
        }
        let mapping = group.members
            .filter { $0.speaker != nil }
            .map { "\($0.mediaRef) (\($0.role.rawValue)) → \($0.speaker!)" }
            .joined(separator: "; ")
        return .ok("Updated speakers on '\(group.name)': \(mapping.isEmpty ? "all cleared" : mapping)")
    }

    // MARK: remove_multicam

    func removeMulticam(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: RemoveMulticamInput = try decodeToolArgs(args, path: "remove_multicam")
        let group = try resolveMulticamGroup(input.groupId, editor: editor)
        withUndoGroup(editor, actionName: "Remove Multicam Group") {
            editor.removeMulticamGroup(id: group.id)
        }
        return .ok("Removed multicam group '\(group.name)' (\(group.id)). Timeline clips were left in place as ordinary clips.")
    }

    // MARK: join_clips

    func joinClips(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: JoinClipsInput = try decodeToolArgs(args, path: "join_clips")
        if let ti = input.trackIndex {
            guard editor.timeline.tracks.indices.contains(ti) else {
                throw ToolError("trackIndex \(ti) out of range (0..\(editor.timeline.tracks.count - 1))")
            }
        }
        if let s = input.startFrame, let e = input.endFrame, s >= e {
            throw ToolError("startFrame (\(s)) must be less than endFrame (\(e))")
        }
        let range: FrameRange? = (input.startFrame != nil || input.endFrame != nil)
            ? FrameRange(start: input.startFrame ?? 0, end: input.endFrame ?? Int.max)
            : nil
        let trackIndices = input.trackIndex.map { [$0] } ?? Array(editor.timeline.tracks.indices)

        var joined = 0
        withUndoGroup(editor, actionName: "Join Clips") {
            for ti in trackIndices {
                joined += editor.joinThroughEdits(trackIndex: ti, in: range)
            }
        }
        guard joined > 0 else {
            return .ok("No through edits found — every seam changes content (different source, discontinuous time, or differing properties). Nothing to join.")
        }
        return .ok("Joined \(joined) through edit\(joined == 1 ? "" : "s"). Clip ids on the merged seams changed — re-read with get_timeline before further edits.")
    }

    // MARK: - Helpers

    private func resolveMulticamGroup(_ groupId: String?, editor: EditorViewModel) throws -> MulticamGroup {
        if let groupId {
            guard let group = editor.multicamGroup(id: groupId) else {
                throw ToolError("Multicam group not found: \(groupId)")
            }
            return group
        }
        let groups = editor.multicamGroups
        guard let first = groups.first else {
            throw ToolError("No multicam groups in this project. Create one with create_multicam.")
        }
        guard groups.count == 1 else {
            throw ToolError("Multiple multicam groups exist — pass groupId. Available: \(groups.map { "\($0.id) ('\($0.name)')" }.joined(separator: ", "))")
        }
        return first
    }
}
