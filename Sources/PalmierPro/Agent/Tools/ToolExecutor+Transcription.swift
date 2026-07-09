import Foundation

struct TranscriptionToolContext {
    let provider: TranscriptionProvider
    let preferredLocale: Locale?
}

struct TimelineWord {
    let index: Int
    let clipId: String
    let trackIndex: Int
    let clipStartFrame: Int
    let clipEndFrame: Int
    let text: String
    let startFrame: Int
    let endFrame: Int
    let speaker: String?
}

struct TimelineTranscript {
    let context: TranscriptionToolContext
    let words: [TimelineWord]
    let skipped: [[String: Any]]

    var includesSpeakers: Bool {
        words.contains { $0.speaker != nil }
    }

    func groups(clipId filter: String? = nil) -> [TimelineTranscriptGroup] {
        var groups: [TimelineTranscriptGroup] = []
        var i = words.startIndex
        while i < words.endIndex {
            let clipId = words[i].clipId
            var j = words.index(after: i)
            while j < words.endIndex, words[j].clipId == clipId { j = words.index(after: j) }
            if filter == nil || filter == clipId {
                groups.append(TimelineTranscriptGroup(
                    clipId: clipId,
                    trackIndex: words[i].trackIndex,
                    clipStartFrame: words[i].clipStartFrame,
                    clipEndFrame: words[i].clipEndFrame,
                    words: words[i..<j]
                ))
            }
            i = j
        }
        return groups
    }

    func responsePayload(
        fps: Int, clipId: String?, startFrame: Int?, endFrame: Int?, maxWords: Int, segments: Bool = false
    ) -> [String: Any] {
        var clipsOut: [[String: Any]] = []
        var totalWords = 0
        var remaining = maxWords
        var lastEnd: Int?
        var speakerRuns: [[Any]] = []
        var currentSpeaker: String??

        for group in groups(clipId: clipId) {
            var visible: [TimelineWord] = []
            for word in group.words {
                if let startFrame, word.endFrame <= startFrame { continue }
                if let endFrame, word.startFrame >= endFrame { continue }
                totalWords += 1
                guard remaining > 0 else { continue }
                visible.append(word)
                remaining -= 1
                lastEnd = word.endFrame
                // Speakers as run-length turns, not a column repeated on every word.
                if includesSpeakers, currentSpeaker != word.speaker {
                    currentSpeaker = word.speaker
                    speakerRuns.append([word.index, word.speaker ?? NSNull()])
                }
            }
            guard !visible.isEmpty else { continue }
            var clipOut: [String: Any] = [
                "clipId": group.clipId,
                "trackIndex": group.trackIndex,
                "startFrame": group.clipStartFrame,
                "endFrame": group.clipEndFrame,
            ]
            if segments {
                clipOut["segments"] = Self.segmentRows(visible, fps: fps)
            } else {
                clipOut["words"] = visible.map { [$0.index, $0.text, $0.startFrame] }
            }
            clipsOut.append(clipOut)
        }

        var out: [String: Any] = [
            "fps": fps,
            "timing": "projectFrames",
            "transcriptionSource": context.provider.rawValue,
            "clips": clipsOut,
        ]
        if segments {
            out["segmentFormat"] = ["firstWordIndex", "text", "start", "end"]
        } else {
            out["wordFormat"] = ["index", "text", "start"]
        }
        if includesSpeakers, !speakerRuns.isEmpty {
            out["speakers"] = speakerRuns
            out["speakersNote"] = "[firstWordIndex, speaker] — each run holds until the next entry."
        }
        if totalWords > maxWords {
            out["totalWords"] = totalWords
            if let lastEnd {
                out["nextStartFrame"] = lastEnd
                out["wordsNote"] = "First \(maxWords) of \(totalWords) words. Continue with startFrame = nextStartFrame."
            }
        }
        if !skipped.isEmpty { out["skipped"] = skipped }
        return out
    }

    /// Sentence-ish rows for comprehension reads; firstWordIndex is the handle back into word mode.
    private static func segmentRows(_ words: [TimelineWord], fps: Int) -> [[Any]] {
        var rows: [[Any]] = []
        var run: [TimelineWord] = []
        func flush() {
            guard let first = run.first, let last = run.last else { return }
            rows.append([first.index, run.map(\.text).joined(separator: " "), first.startFrame, last.endFrame])
            run.removeAll()
        }
        for word in words {
            if let last = run.last,
               last.speaker != word.speaker || word.startFrame - last.endFrame > fps || run.count >= 48 {
                flush()
            }
            run.append(word)
            if word.text.hasSuffix(".") || word.text.hasSuffix("!") || word.text.hasSuffix("?") {
                flush()
            }
        }
        flush()
        return rows
    }
}

struct TimelineTranscriptGroup {
    let clipId: String
    let trackIndex: Int
    let clipStartFrame: Int
    let clipEndFrame: Int
    let words: ArraySlice<TimelineWord>
}

private struct TranscriptFragment {
    let clipId: String
    let trackIndex: Int
    let clip: Clip
    let url: URL
}

extension ToolExecutor {
    static let transcriptWordLimit = 10000

    private static let inspectMaxSegments = 400
    private static let getTranscriptAllowedKeys: Set<String> = ["startFrame", "endFrame", "clipId", "wordTimestamps", "language", "granularity"]

    func transcriptionContext(
        _ args: [String: Any],
        path: String,
        preferLast: Bool = false,
        estimatedCloudCost: () async -> Int
    ) async throws -> TranscriptionToolContext {
        if preferLast, let lastTranscriptContext {
            return lastTranscriptContext
        }
        let account = AccountService.shared
        let cost = await estimatedCloudCost()
        let provider: TranscriptionProvider = Self.canUseCloudTranscription(
            isSignedIn: account.isSignedIn,
            remainingCredits: account.remainingCredits,
            estimatedCost: cost
        ) ? .cloud : .local
        return TranscriptionToolContext(
            provider: provider,
            preferredLocale: provider == .cloud ? nil : try await Self.parseLocale(args, path: path)
        )
    }

    static func canUseCloudTranscription(isSignedIn: Bool, remainingCredits: Int, estimatedCost: Int) -> Bool {
        guard isSignedIn else { return false }
        guard estimatedCost > 0 else { return true }
        return remainingCredits >= estimatedCost
    }

    static func parseLocale(_ args: [String: Any], path: String) async throws -> Locale? {
        guard let lang = args.string("language") else { return nil }
        let candidate = Locale(identifier: lang)
        guard let match = Transcription.matchLocale(candidates: [candidate], supported: await Transcription.supportedLocales()) else {
            throw ToolError("\(path): on-device transcription does not support language '\(lang)'.")
        }
        return match
    }

    static func validateCloudTranscriptionAccess(for request: EditorViewModel.CaptionRequest, in editor: EditorViewModel) async throws {
        guard request.provider == .cloud else { return }
        let cost = await editor.captionCloudCreditCost(for: request)
        let account = AccountService.shared
        guard account.isSignedIn else { throw ToolError("Sign in to use Cloud transcription.") }
        guard cost > 0 else { return }
        let remaining = account.remainingCredits
        guard remaining > 0 else { throw ToolError("Add credits to use Cloud transcription.") }
        if cost > remaining {
            throw ToolError("\(CostEstimator.format(cost)) needed. Only \(remaining.formatted()) remaining.")
        }
    }

    func getTranscript(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.getTranscriptAllowedKeys, path: "get_transcript")
        let clipFilter = args.string("clipId")
        let windowStart = args.int("startFrame")
        let windowEnd = args.int("endFrame")
        if let start = windowStart, let end = windowEnd, start >= end {
            throw ToolError("startFrame (\(start)) must be less than endFrame (\(end))")
        }
        try validateTranscriptClipFilter(clipFilter, editor)

        let granularity = args.string("granularity") ?? "words"
        guard granularity == "words" || granularity == "segments" else {
            throw ToolError("granularity must be 'words' or 'segments' (got '\(granularity)')")
        }

        let context = try await transcriptionContext(args, path: "get_transcript") {
            await editor.captionCloudCreditCost(for: .init(autoDetect: true, provider: .cloud))
        }
        let transcript = try await timelineTranscript(editor, context: context)
        lastTranscriptContext = context

        let out = transcript.responsePayload(
            fps: editor.timeline.fps,
            clipId: clipFilter,
            startFrame: windowStart,
            endFrame: windowEnd,
            maxWords: Self.transcriptWordLimit,
            segments: granularity == "segments"
        )
        guard let json = Self.jsonString(out) else { throw ToolError("Failed to encode transcript") }
        return .ok(json)
    }

    func timelineTranscript(_ editor: EditorViewModel, context: TranscriptionToolContext) async throws -> TimelineTranscript {
        if context.provider == .cloud {
            let request = EditorViewModel.CaptionRequest(autoDetect: true, provider: .cloud)
            try await Self.validateCloudTranscriptionAccess(for: request, in: editor)
        }
        let (words, skipped) = try await timelineWords(editor, context: context)
        return TimelineTranscript(context: context, words: words, skipped: skipped)
    }

    private func validateTranscriptClipFilter(_ clipId: String?, _ editor: EditorViewModel) throws {
        guard let clipId else { return }
        guard editor.findClip(id: clipId) != nil else {
            throw ToolError("Clip \(clipId) not found.")
        }
        guard editor.captionTargets(ids: []).contains(where: { $0.id == clipId }) else {
            throw ToolError("Clip \(clipId) has no transcribable audio. If it's a video with linked audio, scope to the linked audio clip instead.")
        }
    }

    private func timelineWords(_ editor: EditorViewModel, context: TranscriptionToolContext) async throws -> (words: [TimelineWord], skipped: [[String: Any]]) {
        let fps = editor.timeline.fps
        let assetsById = Dictionary(editor.mediaAssets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var fragments: [TranscriptFragment] = []
        var isVideoByURL: [URL: Bool] = [:]
        for clip in editor.captionTargets(ids: []) {
            guard let loc = editor.findClip(id: clip.id), let asset = assetsById[clip.mediaRef] else { continue }
            let isVideo = asset.type == .video
            fragments.append(TranscriptFragment(clipId: clip.id, trackIndex: loc.trackIndex, clip: clip, url: asset.url))
            isVideoByURL[asset.url] = isVideo
        }

        let transcripts = await transcriptsByURL(
            for: fragments,
            fps: fps,
            projectId: editor.projectId,
            context: context,
            isVideoByURL: isVideoByURL
        )

        let registry = editor.speakerRegistry
        let assignments = editor.speakerAssignments
        let speakerMap = await Self.alignedSpeakerLabels(
            fragments: fragments, transcripts: transcripts.results,
            registry: registry, assignments: assignments
        )

        var words: [TimelineWord] = []
        for frag in fragments.sorted(by: { $0.clip.startFrame < $1.clip.startFrame }) {
            guard let transcript = transcripts.results[frag.url] else { continue }
            for row in timelineRows(from: transcript, clip: frag.clip, fps: fps) {
                words.append(TimelineWord(
                    index: words.count,
                    clipId: frag.clipId,
                    trackIndex: frag.trackIndex,
                    clipStartFrame: frag.clip.startFrame,
                    clipEndFrame: frag.clip.endFrame,
                    text: row.text,
                    startFrame: row.start,
                    endFrame: row.end,
                    speaker: row.speaker.map { speakerMap[frag.clip.mediaRef]?[$0] ?? $0 }
                ))
            }
        }
        return (words, transcripts.skipped)
    }

    /// Per-file speaker labels are file-local; align them project-wide by voice fingerprint.
    private static func alignedSpeakerLabels(
        fragments: [TranscriptFragment],
        transcripts: [URL: TranscriptionResult],
        registry: [SpeakerRegistryEntry],
        assignments: [String: [String: Int]]
    ) async -> [String: [String: String]] {
        let namesById = Dictionary(uniqueKeysWithValues: registry.map { ($0.id, $0.name) })
        // The identify run is the source of truth; per-file partial coverage is fine because
        // registry names never collide with raw provider labels.
        if !assignments.isEmpty {
            var map: [String: [String: String]] = [:]
            for (ref, locals) in assignments {
                for (local, gid) in locals {
                    map[ref, default: [:]][local] = namesById[gid] ?? "Speaker \(gid)"
                }
            }
            return map
        }
        var refsByURL: [URL: [String]] = [:]
        var files: [(mediaRef: String, url: URL, turns: [SpeakerIdentity.Turn])] = []
        for frag in fragments {
            let isNewURL = refsByURL[frag.url] == nil
            if refsByURL[frag.url, default: []].contains(frag.clip.mediaRef) == false {
                refsByURL[frag.url, default: []].append(frag.clip.mediaRef)
            }
            guard isNewURL, let transcript = transcripts[frag.url] else { continue }
            let turns = await SpeakerIdentity.speechConfirmed(
                SpeakerIdentity.turns(from: transcript), url: frag.url, mediaRef: frag.clip.mediaRef
            )
            if !turns.isEmpty { files.append((frag.clip.mediaRef, frag.url, turns)) }
        }
        let result = await SpeakerIdentity.assignments(files: files, registry: registry.map { ($0.id, $0.centroid) })
        var map: [String: [String: String]] = [:]
        for (ref, locals) in result.byFileLocal {
            for (local, gid) in locals {
                map[ref, default: [:]][local] = namesById[gid] ?? "Speaker \(gid)"
            }
        }
        // Partial alignment would let a remapped label collide with an untouched local one.
        guard !map.isEmpty, files.allSatisfy({ map[$0.mediaRef] != nil }) else { return [:] }
        for (url, refs) in refsByURL {
            guard let primary = refs.first, let entry = map[primary] else { continue }
            for ref in refs.dropFirst() { map[ref] = entry }
        }
        return map
    }

    private func transcriptsByURL(
        for fragments: [TranscriptFragment],
        fps: Int,
        projectId: String?,
        context: TranscriptionToolContext,
        isVideoByURL: [URL: Bool]
    ) async -> (results: [URL: TranscriptionResult], skipped: [[String: Any]]) {
        let rangesByURL = sourceRangesByURL(fragments, fps: fps)
        let outcomes = await withTaskGroup(of: (URL, Result<TranscriptionResult, Error>).self) { group in
            for url in Set(fragments.map(\.url)) {
                group.addTask {
                    do {
                        switch context.provider {
                        case .local:
                            return (url, .success(try await TranscriptCache.shared.transcript(
                                for: url,
                                isVideo: isVideoByURL[url] ?? true,
                                range: nil,
                                preferredLocale: context.preferredLocale
                            )))
                        case .cloud:
                            return (url, .success(try await CloudTranscription.transcribe(
                                fileURL: url,
                                range: rangesByURL[url],
                                preferredLocale: nil,
                                projectId: projectId
                            )))
                        }
                    } catch {
                        return (url, .failure(error))
                    }
                }
            }
            var collected: [(URL, Result<TranscriptionResult, Error>)] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        var results: [URL: TranscriptionResult] = [:]
        var skipped: [[String: Any]] = []
        for (url, outcome) in outcomes {
            switch outcome {
            case .success(let transcript): results[url] = transcript
            case .failure(let error): skipped.append(["file": url.lastPathComponent, "reason": error.localizedDescription])
            }
        }
        return (results, skipped)
    }

    private func sourceRangesByURL(_ fragments: [TranscriptFragment], fps: Int) -> [URL: ClosedRange<Double>] {
        let rate = Double(fps)
        guard rate > 0 else { return [:] }
        var ranges: [URL: ClosedRange<Double>] = [:]
        for url in Set(fragments.map(\.url)) {
            let spans = fragments.filter { $0.url == url }.map { CaptionTranscriptMapper.sourceSpan(for: $0.clip) }
            guard let lo = spans.map(\.start).min(), let hi = spans.map(\.end).max(), hi > lo else { continue }
            ranges[url] = max(lo / rate - 1.0, 0)...(hi / rate + 1.0)
        }
        return ranges
    }

    private func timelineRows(from transcript: TranscriptionResult, clip: Clip, fps: Int) -> [(start: Int, end: Int, text: String, speaker: String?)] {
        let visible = CaptionTranscriptMapper.sourceSpan(for: clip)
        let rate = Double(fps)
        let rows = transcript.words.compactMap { word -> (start: Int, end: Int, text: String, speaker: String?)? in
            guard let start = word.start, let end = word.end else { return nil }
            let midFrame = (start + end) / 2 * rate
            guard midFrame >= visible.start, midFrame < visible.end,
                  let frameSpan = Self.spanFrames(start: start, end: end, clip: clip, fps: fps) else { return nil }
            return (frameSpan.start, frameSpan.end, word.text, word.speaker)
        }
        return rows.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    func msToFrames(_ ms: Double, fps: Int) -> Int {
        Int((ms / 1000 * Double(fps)).rounded())
    }

    static func timelineMappingMeta(clip: Clip, fps: Int) -> [String: Any] {
        [
            "clipId": clip.id,
            "clipStartFrame": clip.startFrame,
            "clipEndFrame": clip.endFrame,
            "fps": fps,
            "note": "transcription segments/words are project frames for this clip; out-of-range entries are dropped.",
        ]
    }

    static func transcriptionMeta(
        from transcript: TranscriptionResult,
        mapping: (clip: Clip, fps: Int)? = nil,
        includeWords: Bool = false
    ) -> [String: Any] {
        var out: [String: Any] = [
            "timing": mapping == nil ? "sourceSeconds" : "projectFrames",
        ]
        if let lang = transcript.language { out["language"] = lang }

        let rows: [(row: [Any], sourceEnd: Double)]
        if let mapping {
            rows = transcript.segments.compactMap { s in
                guard let f = spanFrames(start: s.start, end: s.end, clip: mapping.clip, fps: mapping.fps) else { return nil }
                return ([s.text, f.start, f.end], s.end)
            }
        } else {
            rows = transcript.segments.map { ([$0.text, round2OrNull($0.start), round2OrNull($0.end)], $0.end) }
        }
        out["segments"] = rows.prefix(inspectMaxSegments).map(\.row)
        if rows.count > inspectMaxSegments, let lastEnd = rows.prefix(inspectMaxSegments).last?.sourceEnd {
            out["totalSegments"] = rows.count
            out["nextStartSeconds"] = round2OrNull(lastEnd)
            out["segmentsNote"] = "First \(inspectMaxSegments) of \(rows.count) segments. Continue with startSeconds = nextStartSeconds."
        }

        if includeWords {
            let words: [[Any]]
            if let mapping {
                words = wordFrames(transcript, clip: mapping.clip, fps: mapping.fps).map { [$0.text, $0.start, $0.end] }
            } else {
                words = transcript.words.map { [$0.text, round2OrNull($0.start), round2OrNull($0.end)] }
            }
            out["words"] = Array(words.prefix(transcriptWordLimit))
            if words.count > transcriptWordLimit {
                out["totalWords"] = words.count
                out["wordsNote"] = "First \(transcriptWordLimit) of \(words.count) words. Narrow with startSeconds/endSeconds."
            }
        }
        return out
    }

    private static func wordFrames(_ transcript: TranscriptionResult, clip: Clip, fps: Int) -> [(text: String, start: Int, end: Int)] {
        transcript.words.compactMap { word in
            guard let start = word.start, let end = word.end,
                  let frames = spanFrames(start: start, end: end, clip: clip, fps: fps) else { return nil }
            return (word.text, frames.start, frames.end)
        }
    }

    private static func spanFrames(start: Double, end: Double, clip: Clip, fps: Int) -> (start: Int, end: Int)? {
        let rate = Double(fps)
        let visible = CaptionTranscriptMapper.sourceSpan(for: clip)
        let startFrame = max(start * rate, visible.start)
        let endFrame = min(end * rate, visible.end)
        guard endFrame > startFrame else { return nil }
        func toTimeline(_ sourceFrame: Double) -> Int {
            Int((Double(clip.startFrame) + (sourceFrame - visible.start) / max(clip.speed, 0.0001)).rounded())
        }
        let mappedStart = toTimeline(startFrame)
        return (mappedStart, max(mappedStart, toTimeline(endFrame)))
    }

    private static func round2OrNull(_ x: Double?) -> Any {
        guard let x, x.isFinite else { return NSNull() }
        return NSDecimalNumber(string: String(format: "%.2f", x))
    }
}
