import Foundation

extension ToolExecutor {

    func manageMulticam(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["create", "ungroup"], path: "manage_multicam")
        let snapshot = timelineSnapshot(editor)
        if let raw = args["create"] {
            guard let body = raw as? [String: Any] else { throw ToolError("manage_multicam.create must be an object.") }
            let created = try await createSection(editor, body)
            return mutationResult(editor, since: snapshot, extra: ["created": created])
        }
        if let raw = args["ungroup"] {
            guard let body = raw as? [String: Any] else { throw ToolError("manage_multicam.ungroup must be an object.") }
            return mutationResult(editor, since: snapshot, extra: ["ungrouped": try ungroupSection(editor, body)])
        }
        throw ToolError("Pass create or ungroup.")
    }

    // MARK: - create

    private func createSection(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> [String: Any] {
        try validateUnknownKeys(args, allowed: ["name", "members", "master", "startFrame", "searchWindowSeconds"], path: "manage_multicam.create")
        guard let rawMembers = args["members"] as? [[String: Any]], rawMembers.count >= 2 else {
            throw ToolError("create.members requires at least two entries (cameras and mics).")
        }

        var specs: [EditorViewModel.MulticamMemberSpec] = []
        var seenRefs = Set<String>()
        for (i, raw) in rawMembers.enumerated() {
            let spec = try memberSpec(raw, path: "create.members[\(i)]", editor: editor)
            guard seenRefs.insert(spec.mediaRef).inserted else {
                throw ToolError("create.members[\(i)]: duplicate mediaRef \(spec.mediaRef)")
            }
            specs.append(spec)
        }

        let masterRef = try resolveMasterRef(args.string("master"), specs: specs, editor: editor)
        let sync = await editor.syncMulticamMembers(
            specs: specs, masterRef: masterRef,
            searchWindowSeconds: args.double("searchWindowSeconds") ?? EditorViewModel.SyncDefaults.memberSearchWindowSeconds
        )

        let (groupId, clipIds) = try withUndoGroup(editor, actionName: "Create Multicam (Agent)") {
            try editor.createMulticamGroup(
                specs: specs, syncMaps: sync.maps, masterRef: masterRef,
                name: args.string("name"), startFrame: args.int("startFrame")
            )
        }

        var payload: [String: Any] = [
            "groupId": groupId,
            "members": memberRows(editor, groupId: groupId),
            "clipIds": clipIds,
        ]
        if !sync.failures.isEmpty {
            payload["needsAttention"] = sync.failures.map { ["mediaRef": $0.mediaRef, "reason": $0.reason] }
        }
        return payload
    }

    // MARK: - Lifecycle sections

    private func ungroupSection(_ editor: EditorViewModel, _ args: [String: Any]) throws -> String {
        try validateUnknownKeys(args, allowed: ["groupId"], path: "manage_multicam.ungroup")
        let groupId = try requireGroup(editor, args.string("groupId"))
        withUndoGroup(editor, actionName: "Ungroup Multicam (Agent)") {
            editor.ungroupMulticam(groupId: groupId)
        }
        return groupId
    }

    // MARK: - change_cam

    func changeCam(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["groupId", "clipId", "entries"], path: "change_cam")
        let groupId = try resolveGroupId(editor, args)
        guard let rawEntries = args["entries"] as? [[String: Any]], !rawEntries.isEmpty else {
            throw ToolError("entries requires at least one {range, angle} entry.")
        }

        var requests: [EditorViewModel.AngleSwitchRequest] = []
        for (i, raw) in rawEntries.enumerated() {
            let path = "entries[\(i)]"
            try validateUnknownKeys(raw, allowed: ["range", "angle", "layout", "angles"], path: path)
            guard let range = raw["range"] as? [Any], range.count == 2,
                  let a = (range[0] as? NSNumber)?.intValue, let b = (range[1] as? NSNumber)?.intValue, a < b else {
                throw ToolError("\(path): range must be [startFrame, endFrame) with start < end.")
            }
            if let layoutRaw = raw["layout"] as? String {
                guard raw["angle"] == nil else {
                    throw ToolError("\(path): pass angle for a full-frame switch OR layout + angles, not both.")
                }
                guard let layout = VideoLayout(rawValue: layoutRaw), layout != .full else {
                    throw ToolError("\(path): unknown layout '\(layoutRaw)'. Valid: \(VideoLayout.allCases.filter { $0 != .full }.map(\.rawValue).joined(separator: ", ")). For full frame, pass angle instead.")
                }
                guard let angles = raw["angles"] as? [String], !angles.isEmpty else {
                    throw ToolError("\(path): layout needs angles — angleLabels in slot order (\(layout.slots.map(\.id).joined(separator: ", "))); fewer than slots leaves cells empty.")
                }
                requests.append(.init(range: a..<b, layout: layout, angles: angles))
            } else {
                requests.append(.init(range: a..<b, angle: try raw.requireString("angle")))
            }
        }

        let snapshot = timelineSnapshot(editor)
        let outcome = try withUndoGroup(editor, actionName: "Switch Angle (Agent)") {
            try editor.switchMulticamAngles(groupId: groupId, requests: requests)
        }

        var extra: [String: Any] = ["groupId": groupId, "switched": outcome.switched]
        if outcome.merged > 0 { extra["cutsMerged"] = outcome.merged }
        if !outcome.overlayClipIds.isEmpty { extra["overlayClipIds"] = outcome.overlayClipIds }
        if let lo = outcome.applied.map(\.lowerBound).min(),
           let hi = outcome.applied.map(\.upperBound).max() {
            extra["program"] = editor.multicamProgramRows(groupId: groupId, window: lo..<hi)
        }
        if !outcome.clamped.isEmpty {
            extra["clamped"] = outcome.clamped.map {
                ["requested": [$0.requested.lowerBound, $0.requested.upperBound],
                 "applied": [$0.applied.lowerBound, $0.applied.upperBound],
                 "culprit": $0.culprit]
            }
        }
        if !outcome.skipped.isEmpty {
            extra["skipped"] = outcome.skipped.map {
                ["range": [$0.range.lowerBound, $0.range.upperBound], "reason": $0.reason]
            }
        }
        return mutationResult(editor, since: snapshot, extra: extra)
    }

    // MARK: - get_multicam

    func getMulticam(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["groupId", "clipId", "startFrame", "endFrame"], path: "get_multicam")
        let groupId = try resolveGroupId(editor, args)
        guard let group = editor.multicamGroup(id: groupId) else {
            throw ToolError("No multicam group '\(groupId)'. get_timeline lists multicamGroups.")
        }
        let window = try Self.frameWindow(args)
        let payload: [String: Any] = [
            "groupId": groupId,
            "name": group.name,
            "members": memberRows(editor, groupId: groupId),
            "program": editor.multicamProgramRows(groupId: groupId, window: window),
            "trackIndexes": editor.multicamTrackIndexes(of: groupId).sorted(),
        ]
        return .ok(Self.jsonString(roundJSONFloatingPointNumbers(payload, toPlaces: 3)) ?? "{}")
    }

    // MARK: - Helpers

    private func memberSpec(_ raw: [String: Any], path: String, editor: EditorViewModel) throws -> EditorViewModel.MulticamMemberSpec {
        try validateUnknownKeys(raw, allowed: ["mediaRef", "kind", "angleLabel", "offsetSeconds"], path: path)
        let ref = try raw.requireString("mediaRef")
        guard let kind = MulticamSource.MemberKind(rawValue: try raw.requireString("kind")) else {
            throw ToolError("\(path): kind must be angle, mic, or both.")
        }
        let asset = try asset(ref, editor: editor, label: "\(path) member")
        switch kind {
        case .angle:
            guard asset.type == .video else { throw ToolError("\(path): angle members must be video.") }
        case .mic:
            guard asset.type == .audio || (asset.type == .video && asset.hasAudio) else {
                throw ToolError("\(path): mic members need audio.")
            }
        case .both:
            guard asset.type == .video && asset.hasAudio else {
                throw ToolError("\(path): 'both' members must be video with audio.")
            }
        }
        return .init(
            mediaRef: ref, kind: kind,
            angleLabel: raw.string("angleLabel"),
            pinnedOffsetSeconds: raw.double("offsetSeconds")
        )
    }

    private func requireGroup(_ editor: EditorViewModel, _ groupId: String?) throws -> String {
        guard let groupId else { throw ToolError("groupId is required.") }
        guard editor.multicamGroup(id: groupId) != nil else {
            throw ToolError("No multicam group '\(groupId)'. get_timeline lists multicamGroups.")
        }
        return groupId
    }

    private func resolveGroupId(_ editor: EditorViewModel, _ args: [String: Any]) throws -> String {
        if let groupId = args.string("groupId") { return try requireGroup(editor, groupId) }
        if let clipId = args.string("clipId") {
            guard let clip = editor.clipFor(id: clipId), let group = editor.multicamGroup(of: clip) else {
                throw ToolError("Clip '\(clipId)' is not part of a multicam group.")
            }
            return group.id
        }
        throw ToolError("Pass groupId or clipId.")
    }

    private func resolveMasterRef(_ master: String?, specs: [EditorViewModel.MulticamMemberSpec], editor: EditorViewModel) throws -> String {
        if let master {
            let expanded = (try? expandingIdPrefixes(in: ["mediaRef": master], editor: editor))?.string("mediaRef") ?? master
            guard let spec = specs.first(where: {
                $0.mediaRef == expanded || $0.angleLabel?.caseInsensitiveCompare(master) == .orderedSame
            }) else {
                throw ToolError("master '\(master)' doesn't match a member's angleLabel or mediaRef.")
            }
            guard spec.kind != .angle else {
                throw ToolError("master '\(master)' is an angle — its audio is scratch. Pick a mic/both member.")
            }
            return spec.mediaRef
        }
        let pick = specs.first { $0.kind == .mic } ?? specs.first { $0.kind == .both } ?? specs[0]
        guard pick.kind != .angle else {
            throw ToolError("No mic member to sync against — mark one member as mic/both, or pin offsets explicitly.")
        }
        return pick.mediaRef
    }

    private func memberRows(_ editor: EditorViewModel, groupId: String) -> [[String: Any]] {
        guard let group = editor.multicamGroup(id: groupId) else { return [] }
        return group.members.map { memberRow($0, masterMemberId: group.masterMemberId) }
    }

    private func memberRow(_ m: MulticamSource.Member, masterMemberId: String?) -> [String: Any] {
        var row: [String: Any] = [
            "angleLabel": m.angleLabel, "kind": m.kind.rawValue, "mediaRef": m.mediaRef,
            "offsetSeconds": m.sync.offsetSeconds, "confidence": m.sync.confidence,
        ]
        if m.id == masterMemberId { row["master"] = true }
        if m.sync.locked { row["pinned"] = true }
        if !m.usable { row["unsynced"] = true }
        return row
    }
}
