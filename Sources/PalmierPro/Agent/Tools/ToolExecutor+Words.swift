import Foundation

extension ToolExecutor {

    private static let removeWordsAllowedKeys: Set<String> = ["words", "cutAggressiveness"]

    func removeWords(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.removeWordsAllowedKeys, path: "remove_words")
        guard let rawWords = args["words"] as? [Any], !rawWords.isEmpty else {
            throw ToolError("Missing or empty 'words'. Pass word indices from get_transcript, e.g. [5, [12, 18]].")
        }
        let aggressiveness: CutAggressiveness
        if let raw = args.string("cutAggressiveness") {
            guard let a = CutAggressiveness(rawValue: raw) else {
                throw ToolError("cutAggressiveness must be one of: \(CutAggressiveness.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            aggressiveness = a
        } else { aggressiveness = .balanced }

        let (allWords, _) = try await timelineWords(editor)
        guard !allWords.isEmpty else { throw ToolError("No transcribable speech on the timeline.") }

        var selected = Set<Int>(), ignored: [Int] = []
        let maxIndex = allWords.count - 1
        for (a, b) in try Self.parseWordSpans(rawWords) {
            for idx in min(a, b)...max(a, b) {
                if (0...maxIndex).contains(idx) { selected.insert(idx) } else { ignored.append(idx) }
            }
        }
        guard !selected.isEmpty else {
            throw ToolError("None of the requested word indices are in range 0...\(maxIndex). Re-read get_transcript.")
        }

        let keepGapFrames = msToFrames(aggressiveness.keptGapMs, fps: editor.timeline.fps)
        var removedTexts: [String] = []
        var rangesByTrack: [Int: [FrameRange]] = [:]
        forEachTimelineClipGroup(in: allWords) { _, trackIndex, clipStart, clipEnd, clipWords in
            guard clipWords.contains(where: { selected.contains($0.index) }) else { return }
            removedTexts.append(contentsOf: clipWords.filter { selected.contains($0.index) }.map(\.text))
            let plan = clipWords.map {
                WordCutPlanner.Word(startFrame: $0.startFrame, endFrame: $0.endFrame, selected: selected.contains($0.index))
            }
            let ranges = WordCutPlanner.cutRanges(words: plan, clipStart: clipStart, clipEnd: clipEnd, keepGapFrames: keepGapFrames)
            if !ranges.isEmpty { rangesByTrack[trackIndex, default: []].append(contentsOf: ranges) }
        }
        guard !rangesByTrack.isEmpty else {
            throw ToolError("The selected words resolved to no removable frames. Re-read get_transcript.")
        }

        editor.undoManager?.beginUndoGrouping()
        let outcome = editor.rippleDeleteRangesOnTracks(rangesByTrack)
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.setActionName("Remove Words (Agent)")
        guard case .ok(let report) = outcome else {
            if case .refused(let reason) = outcome { throw ToolError("Ripple delete refused: \(reason)") }
            throw ToolError("Ripple delete refused.")
        }

        var payload: [String: Any] = [
            "removedWords": removedTexts.count, "removedFrames": report.removedFrames,
            "tracksEdited": rangesByTrack.count, "cutAggressiveness": aggressiveness.rawValue,
            "note": "Removed and closed the gaps. Re-read get_transcript before another remove_words.",
        ]
        let preview = removedTexts.prefix(24).joined(separator: " ")
        if !preview.isEmpty { payload["removedText"] = removedTexts.count > 24 ? preview + " …" : preview }
        if !ignored.isEmpty { payload["indicesIgnored"] = ignored.sorted() }
        guard let json = Self.jsonString(payload) else { throw ToolError("Failed to encode result") }
        return .ok(json)
    }

    static func parseWordSpans(_ raw: [Any]) throws -> [(Int, Int)] {
        try raw.enumerated().map { i, element in
            if let n = intFromAny(element) { return (n, n) }
            guard let pair = element as? [Any], pair.count == 2,
                  let a = intFromAny(pair[0]), let b = intFromAny(pair[1]) else {
                throw ToolError("words[\(i)]: expected an integer index or an [start, end] pair.")
            }
            return (a, b)
        }
    }

    private static func intFromAny(_ v: Any) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let d = v as? Double, d.rounded() == d { return Int(d) }
        return nil
    }
}
