import Foundation

enum AgentMentionContext {
    struct InlinedMentions {
        var blocks: [[String: Any]] = []
        var inlinedIds: Set<String> = []
        var failures: [String: String] = [:]  // mediaRef -> reason
    }

    static func referencedMentions(_ mentions: [AgentMention], in text: String) -> [AgentMention] {
        mentions.filter { text.contains("@\($0.displayName)") }
    }

    /// Frozen at send time so the cached prompt prefix stays byte-stable
    @MainActor
    static func hint(_ mentions: [AgentMention], editor: EditorViewModel?) -> String {
        let entries = mentionEntries(mentions, editor: editor)
        let data = (try? JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "[]"
        let notes = mentionNotes(mentions)
        let suffix = notes.isEmpty ? "" : " " + notes.joined(separator: " ")
        return "Referenced assets and timeline context in this message: \(json).\(suffix)"
    }

    /// Which mentioned images were actually attached this request
    static func inlineNote(for inlined: InlinedMentions) -> String? {
        var parts: [String] = []
        if !inlined.inlinedIds.isEmpty {
            parts.append("These mentioned images are attached inline as image blocks — do not call inspect_media for them: \(inlined.inlinedIds.sorted().joined(separator: ", ")).")
        }
        if !inlined.failures.isEmpty {
            let list = inlined.failures.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
            parts.append("These images could not be attached; tell the user the image could not be read rather than describing it: \(list).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    @MainActor
    static func mentionEntries(_ mentions: [AgentMention], editor: EditorViewModel?) -> [[String: Any]] {
        mentions.map { mention in
            var entry: [String: Any] = [
                "mention": "@\(mention.displayName)",
            ]
            if let timelineRange = mention.timelineRange {
                entry["kind"] = "timelineRange"
                entry["timelineRange"] = timelineRange.summary
                return entry
            }

            entry["kind"] = mention.clipId == nil ? "mediaAsset" : "timelineClip"
            if let mediaRef = mention.mediaRef {
                entry["mediaRef"] = mediaRef
            }
            if let type = mention.type { entry["type"] = type.rawValue }
            if let clipId = mention.clipId {
                entry["clipId"] = clipId
                entry["clip"] = clipSummary(for: clipId, editor: editor)
            }
            return entry
        }
    }

    private static func mentionNotes(_ mentions: [AgentMention]) -> [String] {
        var notes: [String] = []
        if mentions.contains(where: { $0.referencesTimelineClips }) {
            notes.append("Entries with \"clipId\" refer to timeline clips; use clipId for timeline edits and pass it to inspect_media when inspecting visible source media.")
        }
        if mentions.contains(where: { $0.referencesTimelineRange }) {
            notes.append("Entries with \"timelineRange\" refer to selected timeline time spans; their frame ranges are half-open: startFrame inclusive, endFrame exclusive.")
        }
        return notes
    }

    @MainActor
    private static func clipSummary(for clipId: String, editor: EditorViewModel?) -> [String: Any] {
        guard let editor else {
            return ["clipId": clipId, "error": "editor unavailable"]
        }
        guard let loc = editor.findClip(id: clipId) else {
            return ["clipId": clipId, "error": "clip not found"]
        }
        let track = editor.timeline.tracks[loc.trackIndex]
        let clip = track.clips[loc.clipIndex]
        return [
            "clipId": clip.id,
            "mediaRef": clip.mediaRef,
            "mediaType": clip.mediaType.rawValue,
            "sourceClipType": clip.sourceClipType.rawValue,
            "label": editor.clipDisplayLabel(for: clip),
            "trackIndex": loc.trackIndex,
            "trackType": track.type.rawValue,
            "startFrame": clip.startFrame,
            "endFrame": clip.endFrame,
            "durationFrames": clip.durationFrames,
            "trimStartFrame": clip.trimStartFrame,
            "trimEndFrame": clip.trimEndFrame,
            "speed": clip.speed,
        ]
    }
}

struct AgentMention: Identifiable, Hashable, Codable {
    let id: UUID
    let displayName: String
    let mediaRef: String?
    let type: ClipType?
    let clipId: String?
    let timelineRange: AgentTimelineRangeMention?

    var referencesTimelineClips: Bool { clipId != nil }
    var referencesTimelineRange: Bool { timelineRange != nil }
    var referencesTimelineContext: Bool { referencesTimelineClips || referencesTimelineRange }

    init(id: UUID = UUID(), displayName: String, mediaRef: String, type: ClipType, clipId: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.mediaRef = mediaRef
        self.type = type
        self.clipId = clipId
        self.timelineRange = nil
    }

    init(id: UUID = UUID(), displayName: String, timelineRange: AgentTimelineRangeMention) {
        self.id = id
        self.displayName = displayName
        self.mediaRef = nil
        self.type = nil
        self.clipId = nil
        self.timelineRange = timelineRange
    }

    static func makeDisplayName(from raw: String) -> String {
        var result = ""
        var lastWasDash = false
        for ch in raw {
            if ch.isWhitespace || ch == "-" {
                if !lastWasDash { result.append("-") }
                lastWasDash = true
            } else {
                result.append(ch)
                lastWasDash = false
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

extension MediaAsset {
    // Collapses spaces and hyphens so the inserted `@token` stays a single word.
    var mentionDisplayName: String {
        AgentMention.makeDisplayName(from: name)
    }
}

struct AgentTimelineRangeMention: Hashable, Codable {
    let startFrame: Int
    let endFrame: Int
    let durationFrames: Int
    let fps: Int
    let startTimecode: String
    let endTimecode: String
    let durationTimecode: String
    let rangeSemantics: String

    init(range: TimelineRangeSelection, fps: Int) {
        let normalized = range.normalized
        let duration = max(0, normalized.endFrame - normalized.startFrame)
        self.startFrame = normalized.startFrame
        self.endFrame = normalized.endFrame
        self.durationFrames = duration
        self.fps = fps
        self.startTimecode = formatTimecode(frame: normalized.startFrame, fps: fps)
        self.endTimecode = formatTimecode(frame: normalized.endFrame, fps: fps)
        self.durationTimecode = formatTimecode(frame: duration, fps: fps)
        self.rangeSemantics = "startInclusiveEndExclusive"
    }

    var summary: [String: Any] {
        [
            "startFrame": startFrame,
            "endFrame": endFrame,
            "durationFrames": durationFrames,
            "fps": fps,
            "startTimecode": startTimecode,
            "endTimecode": endTimecode,
            "durationTimecode": durationTimecode,
            "rangeSemantics": rangeSemantics,
        ]
    }
}
