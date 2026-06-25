import Foundation

// Entity ids are full UUIDs. Sent verbatim they cost ~36 chars each and dominate large
// get_timeline / get_transcript payloads. We emit the shortest prefix that's unique within
// the project and accept any prefix back: tools always run on full ids (resolved on input),
// and every text response has its known ids shortened on the way out.
extension ToolExecutor {
    private nonisolated static let idPrefixFloor = 8

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

    /// Every entity id the agent can see or name back. One set serves both directions: a min-unique
    /// prefix is distinct across the whole set, so anything we emit resolves to exactly one id.
    func currentIdUniverse(_ editor: EditorViewModel) -> Set<String> {
        var ids = Set<String>()
        for track in editor.timeline.tracks {
            ids.insert(track.id)
            for clip in track.clips {
                ids.insert(clip.id)
                if let captionGroupId = clip.captionGroupId { ids.insert(captionGroupId) }
                if let linkGroupId = clip.linkGroupId { ids.insert(linkGroupId) }
            }
        }
        for asset in editor.mediaAssets { ids.insert(asset.id) }
        for folder in editor.folders { ids.insert(folder.id) }
        return ids
    }

    /// Replaces each known full UUID in a result's text with its short prefix. Unknown UUIDs
    /// (e.g. ones embedded in a filename) aren't in the map and pass through untouched.
    func shorteningIds(in result: ToolResult, editor: EditorViewModel) async -> ToolResult {
        guard result.content.contains(where: { block in
            if case .text = block { return true }
            return false
        }) else { return result }

        let universe = currentIdUniverse(editor)
        guard !universe.isEmpty else { return result }
        return await Task.detached(priority: .utility) {
            Self.shorteningIds(in: result, universe: universe)
        }.value
    }

    nonisolated static func shorteningIds(in result: ToolResult, universe: Set<String>) -> ToolResult {
        let map = shortIdMap(universe)
        guard !map.isEmpty else { return result }
        let uuidRegex = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
        let content = result.content.map { block -> ToolResult.Block in
            guard case .text(let s) = block else { return block }
            return .text(s.replacing(uuidRegex) { map[String($0.output)] ?? String($0.output) })
        }
        return ToolResult(content: content, isError: result.isError)
    }

    /// Maps each id to its shortest prefix (≥ idPrefixFloor) that no other id shares. O(n log n)
    nonisolated static func shortIdMap(_ ids: Set<String>) -> [String: String] {
        let sorted = ids.sorted()
        var out: [String: String] = [:]
        for (i, id) in sorted.enumerated() {
            var sharedLen = 0
            if i > 0 { sharedLen = max(sharedLen, commonPrefixLength(id, sorted[i - 1])) }
            if i < sorted.count - 1 { sharedLen = max(sharedLen, commonPrefixLength(id, sorted[i + 1])) }
            let len = min(id.count, max(idPrefixFloor, sharedLen + 1))
            out[id] = String(id.prefix(len))
        }
        return out
    }

    private nonisolated static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        var i = a.startIndex
        var j = b.startIndex
        while i < a.endIndex, j < b.endIndex, a[i] == b[j] {
            count += 1
            i = a.index(after: i)
            j = b.index(after: j)
        }
        return count
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
