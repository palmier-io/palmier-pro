import Foundation

// get_timeline, create_timeline, set_active_timeline.
extension ToolExecutor {
    private static let getTimelineAllowedKeys: Set<String> = ["startFrame", "endFrame", "captionDetail"]

    func getTimeline(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.getTimelineAllowedKeys, path: "get_timeline")
        let window = try Self.frameWindow(args)
        let captionDetail = args["captionDetail"] as? Bool ?? false

        guard var dict = Self.rawTimelineDict(editor.timeline) else { throw ToolError("Failed to encode timeline") }
        dict.removeValue(forKey: "settingsConfigured")
        if let tracks = dict["tracks"] as? [[String: Any]] {
            dict["tracks"] = Self.compactTracks(tracks, editor: editor, window: window, captionDetail: captionDetail)
        }
        dict["totalFrames"] = editor.timeline.totalFrames
        dict["durationSeconds"] = Double(editor.timeline.totalFrames) / Double(max(editor.timeline.fps, 1))
        if let window {
            dict["window"] = [window.lowerBound, min(window.upperBound, editor.timeline.totalFrames)]
        }
        dict["currentFrame"] = editor.currentFrame
        dict["canGenerate"] = Self.canGenerate
        if editor.timelines.count > 1 {
            dict["timelines"] = timelineEntries(editor)
        }
        guard let json = Self.jsonString(roundJSONFloatingPointNumbers(dict, toPlaces: 3)) else {
            throw ToolError("Failed to encode timeline")
        }
        return .ok(json)
    }

    static var canGenerate: Bool { AccountService.shared.isSignedIn && AccountService.shared.hasCredits }

    static func rawTimelineDict(_ timeline: Timeline) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: JSONEncoder().encode(timeline)) as? [String: Any]
    }

    func timelineEntries(_ editor: EditorViewModel, detailed: Bool = false) -> [[String: Any]] {
        editor.timelines.map { t in
            var e: [String: Any] = ["timelineId": t.id, "name": t.name]
            if t.id == editor.activeTimelineId { e["active"] = true }
            if detailed {
                e["durationSeconds"] = Double(t.totalFrames) / Double(max(t.fps, 1))
                if let path = folderPathString(t.folderId, editor: editor) { e["folder"] = path }
            }
            return e
        }
    }

    private static func frameWindow(_ args: [String: Any]) throws -> Range<Int>? {
        guard args.int("startFrame") != nil || args.int("endFrame") != nil else { return nil }
        let s = args.int("startFrame") ?? 0
        let e = args.int("endFrame") ?? Int.max
        guard s < e else {
            throw ToolError("Invalid window [\(s), \(e)): startFrame must be less than endFrame")
        }
        return s..<e
    }

    func createTimeline(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["name", "from"], path: "create_timeline")
        let id: String
        let note: String
        if let fromRef = args.string("from") {
            guard let source = editor.timeline(for: fromRef) else {
                throw ToolError("No timeline with id '\(fromRef)'. get_media lists the project's timelines.")
            }
            guard let newId = editor.duplicateTimeline(fromRef) else {
                throw ToolError("Couldn't duplicate \"\(source.name)\".")
            }
            id = newId
            if let name = args.string("name") { editor.renameTimeline(id, to: name) }
            note = "Duplicated \"\(source.name)\" and switched to the copy. Its clip and track ids are new — re-read get_timeline before editing."
        } else {
            id = editor.createTimeline(name: args.string("name"))
            note = "Empty and now active; all edit tools target it."
        }
        let payload: [String: Any] = [
            "timelineId": id,
            "name": editor.timeline(for: id)?.name ?? "",
            "active": true,
            "note": note,
        ]
        return .ok(Self.jsonString(payload) ?? "{}")
    }

    func setActiveTimeline(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["timelineId"], path: "set_active_timeline")
        guard let id = args.string("timelineId") else { throw ToolError("timelineId is required") }
        guard let target = editor.timeline(for: id) else {
            throw ToolError("No timeline with id '\(id)'. get_media lists the project's timelines.")
        }
        var payload: [String: Any] = [
            "timelineId": target.id,
            "name": target.name,
            "active": true,
            "totalFrames": target.totalFrames,
            "fps": target.fps,
            "trackCount": target.tracks.count,
        ]
        if editor.activeTimelineId == target.id {
            payload["note"] = "Already the active timeline."
        } else {
            editor.activateTimeline(target.id)
            payload["note"] = "Re-read get_timeline — clip and track ids from the previous timeline no longer apply."
        }
        return .ok(Self.jsonString(payload) ?? "{}")
    }

    // MARK: - Payload shaping

    private static let captionRowLimit = 200
    private static let captionRowFormat = ["clipId", "startFrame", "endFrame", "text"]
    private static let captionPreviewLimit = 60

    private static let trackDefaults: [String: Any] = ["muted": false, "hidden": false, "syncLocked": true]

    private static let clipDefaults: [String: Any] = {
        var clip = Clip(mediaRef: "", startFrame: 0, durationFrames: 0)
        clip.textStyle = TextStyle()
        guard let data = try? JSONEncoder().encode(clip),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        // Identity fields stay; sourceClipType strips only when it matches mediaType.
        for key in ["id", "mediaRef", "startFrame", "durationFrames", "sourceClipType"] {
            obj.removeValue(forKey: key)
        }
        return obj
    }()

    static func compactTracks(
        _ tracks: [[String: Any]], editor: EditorViewModel, window: Range<Int>?, captionDetail: Bool
    ) -> [[String: Any]] {
        let fold = linkFoldPlan(tracks)
        var grades: [String: [String: Any]] = [:]
        for track in editor.timeline.tracks {
            for clip in track.clips {
                if let c = colorObject(from: clip.effects) { grades[clip.id] = c }
            }
        }
        return tracks.indices.map { i in
            var track = compactTrack(tracks[i], window: window, captionDetail: captionDetail, fold: fold, grades: grades)
            // Report the displayed label (mirrored video numbering), not the stored seed.
            track["label"] = editor.timelineTrackDisplayLabel(at: i)
            track["index"] = i
            track.removeValue(forKey: "id")
            track.removeValue(forKey: "displayHeight")
            if let count = fold.foldedCountByTrack[i] { track["linkedClips"] = count }
            let gaps = trackGaps(editor.timeline.tracks[i])
            if !gaps.isEmpty { track["gaps"] = gaps }
            return track
        }
    }

    /// Empty spans between non-caption clips; leading/trailing space reads off the clip frames.
    private static func trackGaps(_ track: Track) -> [[Int]] {
        let spans = track.clips
            .filter { $0.captionGroupId == nil }
            .map { [$0.startFrame, $0.startFrame + $0.durationFrames] }
            .sorted { $0[0] < $1[0] }
        var gaps: [[Int]] = []
        var maxEnd: Int?
        for span in spans {
            if let m = maxEnd, span[0] > m { gaps.append([m, span[0]]) }
            maxEnd = max(maxEnd ?? span[1], span[1])
        }
        return gaps
    }

    // MARK: - Linked audio fold

    /// Visual+audio linked pairs fold into the visual clip; linkage reads structurally, not via linkGroupId.
    struct LinkFold {
        var partnerByVisualId: [String: (clip: [String: Any], trackIndex: Int)] = [:]
        var foldedAudioIds: Set<String> = []
        var foldedCountByTrack: [Int: Int] = [:]
    }

    private static func linkFoldPlan(_ tracks: [[String: Any]]) -> LinkFold {
        var groups: [String: [(clip: [String: Any], trackIndex: Int)]] = [:]
        for (ti, track) in tracks.enumerated() {
            for clip in track["clips"] as? [[String: Any]] ?? [] {
                if let gid = clip["linkGroupId"] as? String {
                    groups[gid, default: []].append((clip, ti))
                }
            }
        }
        var plan = LinkFold()
        for members in groups.values where members.count == 2 {
            guard let audio = members.first(where: { ($0.clip["mediaType"] as? String) == "audio" }),
                  let visual = members.first(where: { ($0.clip["mediaType"] as? String) != "audio" }),
                  let visualId = visual.clip["id"] as? String,
                  let audioId = audio.clip["id"] as? String else { continue }
            plan.partnerByVisualId[visualId] = (audio.clip, audio.trackIndex)
            plan.foldedAudioIds.insert(audioId)
            plan.foldedCountByTrack[audio.trackIndex, default: 0] += 1
        }
        return plan
    }

    /// The folded audio partner: id, track, and only what deviates from its visual clip.
    private static func audioSummary(
        _ partner: [String: Any], trackIndex: Int, visual: [String: Any]
    ) -> [String: Any] {
        var out: [String: Any] = ["id": partner["id"] ?? "", "track": trackIndex]
        let pStart = intValue(partner["startFrame"])
        let pDur = intValue(partner["durationFrames"])
        if pStart != intValue(visual["startFrame"]) || pDur != intValue(visual["durationFrames"]) {
            out["frames"] = [pStart, pStart + pDur]
        }
        for key in ["trimStartFrame", "trimEndFrame", "speed"] {
            if let pv = partner[key] as? NSNumber, let vv = visual[key] as? NSNumber, pv != vv {
                out[key] = pv
            }
        }
        let stripped = strippingDefaults(compactClipKeyframes(partner), clipDefaults)
        for key in ["volume", "fadeInFrames", "fadeOutFrames", "fadeInInterpolation", "fadeOutInterpolation", "keyframes"] {
            if let v = stripped[key] { out[key] = v }
        }
        if let fx = stripped["effects"] as? [[String: Any]] {
            let cleaned = compactEffects(fx)
            if !cleaned.isEmpty { out["effects"] = cleaned }
        }
        return out
    }

    /// Read shape for the effect stack: no ids (removal is by type), flat params, enabled
    /// only when false. color.* entries live in the clip's `color` object instead.
    private static func compactEffects(_ raw: [[String: Any]]) -> [[String: Any]] {
        raw.compactMap { e in
            guard let type = e["type"] as? String, !type.hasPrefix("color.") else { return nil }
            var out: [String: Any] = ["type": type]
            if let params = e["params"] as? [String: Any] {
                var flat: [String: Any] = [:]
                for (k, v) in params {
                    guard let p = v as? [String: Any] else { flat[k] = v; continue }
                    flat[k] = p["value"] ?? p["string"] ?? (p["track"] != nil ? "animated" : nil) ?? v
                }
                if !flat.isEmpty { out["params"] = flat }
            }
            if let enabled = e["enabled"] as? Bool, !enabled { out["enabled"] = false }
            return out
        }
    }

    // MARK: - Track and clip compaction

    private static func compactTrack(
        _ track: [String: Any], window: Range<Int>?, captionDetail: Bool, fold: LinkFold, grades: [String: [String: Any]]
    ) -> [String: Any] {
        var out = strippingDefaults(track, trackDefaults)
        guard let rawClips = track["clips"] as? [[String: Any]] else { return out }
        let compacted = rawClips
            .filter { !fold.foldedAudioIds.contains(($0["id"] as? String) ?? "") }
            .map { compactClip($0, fold: fold, grades: grades) }

        var loose: [[String: Any]] = []
        var groupOrder: [String] = []
        var grouped: [String: [[String: Any]]] = [:]
        for clip in compacted {
            if let gid = clip["captionGroupId"] as? String {
                if grouped[gid] == nil { groupOrder.append(gid) }
                grouped[gid, default: []].append(clip)
            } else {
                loose.append(clip)
            }
        }

        var groups: [[String: Any]] = []
        for gid in groupOrder {
            let (group, deviants) = captionGroup(gid: gid, members: grouped[gid] ?? [], window: window, detail: captionDetail)
            groups.append(group)
            loose.append(contentsOf: deviants)
        }
        loose.sort { intValue(($0["frames"] as? [Any])?.first) < intValue(($1["frames"] as? [Any])?.first) }

        let visible = window.map { w in loose.filter { clipIntersects($0, w) } } ?? loose
        out.removeValue(forKey: "clips")
        if !visible.isEmpty { out["clips"] = visible }
        if visible.count < loose.count { out["totalClips"] = loose.count }
        if !groups.isEmpty { out["captionGroups"] = groups }
        return out
    }

    private static func compactClip(
        _ clip: [String: Any], fold: LinkFold, grades: [String: [String: Any]]
    ) -> [String: Any] {
        var out = compactClipKeyframes(clip)
        if let s = out["sourceClipType"] as? String, s == out["mediaType"] as? String {
            out.removeValue(forKey: "sourceClipType")
        }
        // Text has no source media; trims are placement bookkeeping, not signal.
        if out["mediaType"] as? String == "text" {
            out.removeValue(forKey: "trimStartFrame")
            out.removeValue(forKey: "trimEndFrame")
        }
        out = strippingDefaults(out, clipDefaults)
        if let id = out["id"] as? String, let grade = grades[id] { out["color"] = grade }
        if let fx = out["effects"] as? [[String: Any]] {
            let cleaned = compactEffects(fx)
            if cleaned.isEmpty { out.removeValue(forKey: "effects") } else { out["effects"] = cleaned }
        }
        let start = intValue(out["startFrame"])
        out["frames"] = [start, start + intValue(out["durationFrames"])]
        out.removeValue(forKey: "startFrame")
        out.removeValue(forKey: "durationFrames")
        if let id = out["id"] as? String, let partner = fold.partnerByVisualId[id] {
            out["audio"] = audioSummary(partner.clip, trackIndex: partner.trackIndex, visual: clip)
            out.removeValue(forKey: "linkGroupId")
        }
        return out
    }

    /// Removes keys whose values equal the defaults; recurses into nested objects.
    private static func strippingDefaults(_ dict: [String: Any], _ defaults: [String: Any]) -> [String: Any] {
        var out = dict
        for (key, def) in defaults {
            guard let val = out[key] else { continue }
            if let v = val as? [String: Any], let d = def as? [String: Any] {
                let stripped = strippingDefaults(v, d)
                if stripped.isEmpty { out.removeValue(forKey: key) } else { out[key] = stripped }
            } else if (val as? NSObject)?.isEqual(def) == true {
                out.removeValue(forKey: key)
            }
        }
        return out
    }

    // MARK: - Caption groups

    /// Collapses one caption group into shared properties + a summary (default) or compact rows (detail).
    private static func captionGroup(
        gid: String, members: [[String: Any]], window: Range<Int>?, detail: Bool
    ) -> (group: [String: Any], deviants: [[String: Any]]) {
        let rowKeys: Set<String> = ["id", "frames", "textContent", "captionGroupId", "wordTimings"]
        var counts: [String: Int] = [:]
        var modalKey = ""
        var shared: [String: Any] = [:]
        let entries: [(clip: [String: Any], key: String)] = members.map { clip in
            var residual = clip.filter { !rowKeys.contains($0.key) }
            // Caption boxes are auto-fit per text; size is derived data, not signal.
            if var t = residual["transform"] as? [String: Any] {
                t.removeValue(forKey: "width")
                t.removeValue(forKey: "height")
                if t.isEmpty { residual.removeValue(forKey: "transform") } else { residual["transform"] = t }
            }
            let key = canonicalJSON(residual)
            counts[key, default: 0] += 1
            if counts[key]! > counts[modalKey, default: 0] {
                modalKey = key
                shared = residual
            }
            return (clip, key)
        }

        var rows: [[Any]] = []
        var deviants: [[String: Any]] = []
        var frameMin = Int.max
        var frameMax = 0
        for (clip, key) in entries {
            let frames = clip["frames"] as? [Any]
            let start = intValue(frames?.first)
            let end = intValue(frames?.last)
            frameMin = min(frameMin, start)
            frameMax = max(frameMax, end)
            if key == modalKey {
                rows.append([clip["id"] ?? "", start, end, clip["textContent"] ?? ""])
            } else {
                deviants.append(clip)
            }
        }

        let total = rows.count
        if let window {
            rows = rows.filter { intValue($0[1]) < window.upperBound && intValue($0[2]) > window.lowerBound }
        }
        rows.sort { intValue($0[1]) < intValue($1[1]) }

        var group: [String: Any] = [
            "captionGroupId": gid,
            "clipCount": total,
            "frameRange": [frameMin, frameMax],
        ]
        if !shared.isEmpty { group["shared"] = shared }

        guard detail else {
            if let first = rows.first?[3] as? String, let last = rows.last?[3] as? String {
                group["textPreview"] = rows.count == 1
                    ? truncate(first)
                    : "\(truncate(first)) … \(truncate(last))"
            }
            group["clipsNote"] = "Per-clip rows omitted — re-read with captionDetail:true for \(captionRowFormat) rows; get_transcript has the spoken words."
            return (group, deviants)
        }

        let shown = Array(rows.prefix(captionRowLimit))
        group["clipFormat"] = captionRowFormat
        group["clips"] = shown
        if shown.count < total {
            group["clipsNote"] = "Showing \(shown.count) of \(total) caption clips. Page with startFrame/endFrame."
        }
        return (group, deviants)
    }

    private static func truncate(_ text: String) -> String {
        text.count > captionPreviewLimit ? String(text.prefix(captionPreviewLimit)) + "…" : text
    }

    // MARK: - Keyframes

    private static func compactClipKeyframes(_ clip: [String: Any]) -> [String: Any] {
        var out = clip
        var keyframes: [String: Any] = [:]
        for (trackKey, propKey, valueShape) in [
            ("volumeTrack", "volume", KeyframeValueShape.scalar),
            ("opacityTrack", "opacity", KeyframeValueShape.scalar),
            ("rotationTrack", "rotation", KeyframeValueShape.scalar),
            ("positionTrack", "position", KeyframeValueShape.pair),
            ("scaleTrack", "scale", KeyframeValueShape.pair),
            ("cropTrack", "crop", KeyframeValueShape.crop),
        ] {
            defer { out.removeValue(forKey: trackKey) }
            guard let track = clip[trackKey] as? [String: Any],
                  let kfs = track["keyframes"] as? [[String: Any]],
                  !kfs.isEmpty else { continue }

            let values = kfs.map { valueShape.values(from: $0["value"]).map { ($0 as? NSNumber)?.doubleValue ?? 0 } }
            if let first = values.first, values.allSatisfy({ nearlyEqual($0, first) }),
               collapseConstantKeyframes(first, propKey: propKey, clip: clip, into: &out) {
                continue
            }

            keyframes[propKey] = kfs.map { kf -> [Any] in
                var row: [Any] = [kf["frame"] ?? 0]
                row.append(contentsOf: valueShape.values(from: kf["value"]))
                if let interp = kf["interpolationOut"] as? String, interp != "smooth" {
                    row.append(interp)
                }
                return row
            }
        }
        if !keyframes.isEmpty { out["keyframes"] = keyframes }
        return out
    }

    /// True when absorbed: identity tracks vanish; constants become the static field when it's at default.
    private static func collapseConstantKeyframes(
        _ value: [Double], propKey: String, clip: [String: Any], into out: inout [String: Any]
    ) -> Bool {
        switch propKey {
        case "volume", "opacity":
            if nearlyEqual(value, [1]) { return true }
            guard (clip[propKey] as? NSNumber)?.doubleValue == 1 else { return false }
            out[propKey] = value[0]
            return true
        case "rotation":
            return nearlyEqual(value, [0])
        case "position":
            return nearlyEqual(value, [0, 0])
        case "scale":
            return nearlyEqual(value, [1, 1])
        case "crop":
            if nearlyEqual(value, [0, 0, 0, 0]) { return true }
            let staticCrop = clip["crop"] as? [String: Any] ?? [:]
            guard staticCrop.values.allSatisfy({ (($0 as? NSNumber)?.doubleValue ?? 0) == 0 }) else { return false }
            out["crop"] = ["top": value[0], "right": value[1], "bottom": value[2], "left": value[3]]
            return true
        default:
            return false
        }
    }

    private static func nearlyEqual(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.0005 }
    }

    private enum KeyframeValueShape {
        case scalar, pair, crop

        func values(from raw: Any?) -> [Any] {
            switch self {
            case .scalar:
                return [raw ?? 0]
            case .pair:
                guard let v = raw as? [String: Any] else { return [0, 0] }
                return [v["a"] ?? 0, v["b"] ?? 0]
            case .crop:
                guard let v = raw as? [String: Any] else { return [0, 0, 0, 0] }
                return [v["top"] ?? 0, v["right"] ?? 0, v["bottom"] ?? 0, v["left"] ?? 0]
            }
        }
    }

    // MARK: - Small helpers

    private static func canonicalJSON(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func clipIntersects(_ clip: [String: Any], _ window: Range<Int>) -> Bool {
        let frames = clip["frames"] as? [Any]
        return intValue(frames?.first) < window.upperBound && intValue(frames?.last) > window.lowerBound
    }

    private static func intValue(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
}
