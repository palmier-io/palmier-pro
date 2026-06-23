import Foundation

// Entity ids are full UUIDs. Sent verbatim they cost ~36 chars each and dominate large
// get_timeline / get_transcript payloads. We emit the shortest prefix that's unique within
// the project and accept any prefix back: tools always run on full ids (resolved on input),
// and every text response has its known ids shortened on the way out.
extension ToolExecutor {
    private static let idPrefixFloor = 8

    private static let scalarIdKeys: Set<String> = [
        "clipId", "sourceClipId", "referenceClipId", "targetClipId",
        "mediaRef", "startFrameMediaRef", "endFrameMediaRef",
        "sourceVideoMediaRef", "videoSourceMediaRef",
        "folderId", "parentFolderId",
    ]
    private static let arrayIdKeys: Set<String> = [
        "clipIds", "targetClipIds", "assetIds", "folderIds",
        "referenceMediaRefs", "referenceImageMediaRefs",
        "referenceVideoMediaRefs", "referenceAudioMediaRefs",
    ]

    private static let uuidRegex = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/

    /// Every entity id the agent can see or name back. One set serves both directions: a min-unique
    /// prefix is distinct across the whole set, so anything we emit resolves to exactly one id.
    func currentIdUniverse(_ editor: EditorViewModel) -> Set<String> {
        var ids = Set<String>()
        for track in editor.timeline.tracks {
            ids.insert(track.id)
            for clip in track.clips {
                ids.insert(clip.id)
                clip.captionGroupId.map { ids.insert($0) }
                clip.linkGroupId.map { ids.insert($0) }
            }
        }
        for asset in editor.mediaAssets { ids.insert(asset.id) }
        for folder in editor.folders { ids.insert(folder.id) }
        return ids
    }

    /// Replaces each known full UUID in a result's text with its short prefix. Unknown UUIDs
    /// (e.g. ones embedded in a filename) aren't in the map and pass through untouched.
    func shorteningIds(in result: ToolResult, editor: EditorViewModel) -> ToolResult {
        let map = Self.shortIdMap(currentIdUniverse(editor))
        guard !map.isEmpty else { return result }
        let content = result.content.map { block -> ToolResult.Block in
            guard case .text(let s) = block else { return block }
            return .text(s.replacing(Self.uuidRegex) { map[String($0.output)] ?? String($0.output) })
        }
        return ToolResult(content: content, isError: result.isError)
    }

    /// Maps each id to its shortest prefix (≥ 8 chars) that no other id shares.
    static func shortIdMap(_ ids: Set<String>) -> [String: String] {
        var out: [String: String] = [:]
        for id in ids {
            var len = idPrefixFloor
            while len < id.count, ids.contains(where: { $0 != id && $0.hasPrefix(id.prefix(len)) }) {
                len += 1
            }
            out[id] = String(id.prefix(len))
        }
        return out
    }

    /// Expands id-prefix arguments back to full ids before a tool runs. Throws on an ambiguous prefix;
    /// leaves unknown values untouched so the tool emits its own not-found error.
    func expandingIdPrefixes(in args: [String: Any], editor: EditorViewModel) throws -> [String: Any] {
        let universe = currentIdUniverse(editor)
        return try Self.expand(args, universe: universe) as? [String: Any] ?? args
    }

    private static func expand(_ value: Any, universe: Set<String>) throws -> Any {
        if let dict = value as? [String: Any] {
            var out = dict
            for (key, v) in dict {
                if scalarIdKeys.contains(key), let s = v as? String {
                    out[key] = try expandOne(s, universe: universe)
                } else if arrayIdKeys.contains(key), let arr = v as? [Any] {
                    out[key] = try arr.map { try ($0 as? String).map { try expandOne($0, universe: universe) } ?? $0 }
                } else {
                    out[key] = try expand(v, universe: universe)
                }
            }
            return out
        }
        if let arr = value as? [Any] { return try arr.map { try expand($0, universe: universe) } }
        return value
    }

    private static func expandOne(_ ref: String, universe: Set<String>) throws -> String {
        if universe.contains(ref) { return ref }
        let matches = universe.filter { $0.hasPrefix(ref) }
        if matches.count == 1 { return matches.first! }
        if matches.count > 1 {
            throw ToolError("Ambiguous id '\(ref)' matches \(matches.count) items; re-read with get_timeline or get_media for current ids.")
        }
        return ref
    }
}
