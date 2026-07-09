import Foundation

extension ToolExecutor {

    private static let removeWordsAllowedKeys: Set<String> = ["words", "matches", "cutAggressiveness", "language"]

    func removeWords(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.removeWordsAllowedKeys, path: "remove_words")
        let rawWords = args["words"] as? [Any]
        let rawMatches = args["matches"] as? [Any]
        if rawWords?.isEmpty == true || rawMatches?.isEmpty == true {
            throw ToolError("remove_words: words or matches must not be empty.")
        }
        guard rawWords != nil || rawMatches != nil else {
            throw ToolError("Missing 'words' or 'matches'. Pass word indices from get_transcript, e.g. [5, [12, 18]], or exact words like [\"um\", \"uh\"].")
        }
        guard rawWords == nil || rawMatches == nil else {
            throw ToolError("remove_words: pass either words or matches, not both.")
        }
        let aggressiveness: CutAggressiveness
        if let raw = args.string("cutAggressiveness") {
            guard let a = CutAggressiveness(rawValue: raw) else {
                throw ToolError("cutAggressiveness must be one of: \(CutAggressiveness.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            aggressiveness = a
        } else { aggressiveness = .balanced }

        let context = try await transcriptionContext(args, path: "remove_words", preferLast: true) {
            await editor.captionCloudCreditCost(for: .init(autoDetect: true, provider: .cloud))
        }
        let transcript = try await timelineTranscript(editor, context: context)
        let allWords = transcript.words
        guard !allWords.isEmpty else { throw ToolError("No transcribable speech on the timeline.") }

        var selected = Set<Int>(), ignored: [Int] = []
        let maxIndex = allWords.count - 1
        if let rawWords {
            for (a, b) in try Self.parseWordSpans(rawWords) {
                let lo = min(a, b), hi = max(a, b)
                // Clamp to the valid transcript range so an out-of-range span can't iterate billions of times.
                if hi < 0 || lo > maxIndex { ignored.append(lo); continue }
                if lo < 0 { ignored.append(lo) }
                if hi > maxIndex { ignored.append(hi) }
                for idx in max(0, lo)...min(maxIndex, hi) { selected.insert(idx) }
            }
            guard !selected.isEmpty else {
                throw ToolError("None of the requested word indices are in range 0...\(maxIndex). Re-read get_transcript.")
            }
        } else if let rawMatches {
            let matches = try Self.parseWordMatches(rawMatches)
            for word in allWords where matches.contains(Self.normalizedWordMatch(word.text)) {
                selected.insert(word.index)
            }
            guard !selected.isEmpty else {
                throw ToolError("No transcript words matched: \(matches.sorted().joined(separator: ", ")). Re-read get_transcript or pass exact word indices.")
            }
        }

        let keepGapFrames = msToFrames(aggressiveness.keptGapMs, fps: editor.timeline.fps)
        var removedTexts: [String] = []
        var rangesByTrack: [Int: [FrameRange]] = [:]
        var involvedClips: [String] = []
        for group in transcript.groups() {
            let clipId = group.clipId
            let trackIndex = group.trackIndex
            let clipStart = group.clipStartFrame
            let clipEnd = group.clipEndFrame
            let clipWords = group.words
            guard clipWords.contains(where: { selected.contains($0.index) }) else { continue }
            removedTexts.append(contentsOf: clipWords.filter { selected.contains($0.index) && $0.endFrame > $0.startFrame }.map(\.text))
            let plan = clipWords.map {
                WordCutPlanner.Word(startFrame: $0.startFrame, endFrame: $0.endFrame, selected: selected.contains($0.index))
            }
            let ranges = WordCutPlanner.cutRanges(words: plan, clipStart: clipStart, clipEnd: clipEnd, keepGapFrames: keepGapFrames)
            if !ranges.isEmpty {
                rangesByTrack[trackIndex, default: []].append(contentsOf: ranges)
                involvedClips.append(clipId)
            }
        }
        guard !rangesByTrack.isEmpty else {
            throw ToolError("The selected words resolved to no removable frames. Re-read get_transcript.")
        }

        // Cut one track; the ripple carries its linked A/V partners across the same span.
        let primaryTrack: Int
        if rangesByTrack.count == 1 {
            primaryTrack = rangesByTrack.first!.key
        } else {
            // Multiple tracks are only coherent as one linked unit (e.g. camera + mic); otherwise
            // cutting them together breaks alignment.
            let groupIds: [String] = involvedClips.compactMap { id in
                editor.findClip(id: id).flatMap { editor.timeline.tracks[$0.trackIndex].clips[$0.clipIndex].linkGroupId }
            }
            guard groupIds.count == involvedClips.count, Set(groupIds).count == 1 else {
                let tracks = rangesByTrack.keys.sorted().map(String.init).joined(separator: ", ")
                throw ToolError("Selected words span multiple unlinked tracks (\(tracks)). Remove words one track at a time — linked video/audio is cut automatically. If these tracks are the same source (e.g. camera + mic), link them into one unit first.")
            }
            primaryTrack = rangesByTrack.keys.min()!
        }
        // Use only the primary track's own ranges; the ripple removes the same span from linked
        // partners, so flattening foreign-track frames here would over-cut the primary track.
        let primaryRanges = rangesByTrack[primaryTrack]!

        let snapshot = timelineSnapshot(editor)
        editor.undoManager?.beginUndoGrouping()
        let outcome = editor.rippleDeleteRangesOnTrack(trackIndex: primaryTrack, ranges: primaryRanges)
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.setActionName("Remove Words (Agent)")
        guard case .ok(let report) = outcome else {
            if case .refused(let reason) = outcome { throw ToolError("Ripple delete refused: \(reason)") }
            throw ToolError("Ripple delete refused.")
        }

        var extra: [String: Any] = [
            "removedWords": removedTexts.count, "removedFrames": report.removedFrames,
            "cutAggressiveness": aggressiveness.rawValue,
            "transcriptionSource": context.provider.rawValue,
        ]
        let preview = removedTexts.prefix(24).joined(separator: " ")
        if !preview.isEmpty { extra["removedText"] = removedTexts.count > 24 ? preview + " …" : preview }
        if !ignored.isEmpty { extra["indicesIgnored"] = ignored.sorted() }
        return mutationResult(
            editor, since: snapshot, extra: extra,
            notes: ["Word indices shifted — re-read get_transcript before another remove_words."]
        )
    }

    func removeSilence(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: [], path: "remove_silence")
        let snapshot = timelineSnapshot(editor)
        editor.undoManager?.beginUndoGrouping()
        let result = editor.removeAllDeadAir()
        editor.undoManager?.endUndoGrouping()
        guard let result else {
            throw ToolError("No dead air on the timeline. Speech analysis may still be running, or the audio has no quiet non-speech sections.")
        }
        editor.undoManager?.setActionName("Remove Silence (Agent)")
        if let refusal = result.refusal, result.sections == 0 {
            throw ToolError("Ripple delete refused: \(refusal)")
        }
        var notes: [String] = []
        if let refusal = result.refusal {
            notes.append("A later track refused: \(refusal). Earlier tracks were already edited.")
        }
        return mutationResult(
            editor, since: snapshot,
            extra: ["sectionsRemoved": result.sections, "removedFrames": result.removedFrames],
            notes: notes
        )
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

    static func parseWordMatches(_ raw: [Any]) throws -> Set<String> {
        let matches = try raw.enumerated().map { i, element in
            guard let text = element as? String else {
                throw ToolError("matches[\(i)]: expected a string.")
            }
            let normalized = normalizedWordMatch(text)
            guard !normalized.isEmpty else {
                throw ToolError("matches[\(i)]: expected a non-empty word.")
            }
            return normalized
        }
        return Set(matches)
    }

    static func normalizedWordMatch(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
    }

    private static func intFromAny(_ v: Any) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let d = v as? Double, d.rounded() == d { return safeInt(d) }
        return nil
    }
}
