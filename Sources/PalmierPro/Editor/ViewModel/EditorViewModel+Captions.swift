import CoreGraphics
import Foundation

extension EditorViewModel {
    struct CaptionRequest {
        var sourceClipIds: [String] = []
        var autoDetect: Bool = false
        var style: TextStyle = TextStyle()
        var center: CGPoint = AppTheme.Caption.defaultCenter
        var textCase: CaptionCase = .auto
        var censorProfanity: Bool = false
        var locale: Locale? = nil
        var maxCharacters: Int? = nil
        var maxWords: Int? = nil
        var animation: TextAnimation = TextAnimation()
        var transcriptionProvider: CaptionTranscriptionProvider = .local
    }

    enum CaptionCase: String, CaseIterable, Sendable {
        case auto, upper, lower

        var label: String {
            switch self {
            case .auto: "Auto"
            case .upper: "UPPERCASE"
            case .lower: "lowercase"
            }
        }

        func apply(_ s: String) -> String {
            switch self {
            case .auto: s
            case .upper: s.uppercased()
            case .lower: s.lowercased()
            }
        }
    }

    func captionLineFits(_ line: String, style: TextStyle) -> Bool {
        let size = TextLayout.naturalSize(
            content: line, style: style, maxWidth: .greatestFiniteMagnitude, canvasHeight: CGFloat(timeline.height)
        )
        return size.width <= captionSafeMaxTextWidth
    }

    private var captionSafeWidthRatio: CGFloat {
        max(.zero, CGFloat(AppTheme.Caption.maxPosition - AppTheme.Caption.minPosition) - AppTheme.Caption.horizontalSafeInsetRatio * 2)
    }

    private var captionSafeHeightRatio: CGFloat {
        max(.zero, CGFloat(AppTheme.Caption.maxPosition - AppTheme.Caption.minPosition) - AppTheme.Caption.verticalSafeInsetRatio * 2)
    }

    private var captionSafeMaxTextWidth: CGFloat {
        CGFloat(timeline.width) * min(AppTheme.ComponentSize.captionPreviewMaxTextWidthRatio, captionSafeWidthRatio)
    }

    private var captionSafeMaxTextHeight: CGFloat {
        CGFloat(timeline.height) * captionSafeHeightRatio
    }

    enum CaptionError: LocalizedError {
        case noSource
        case noCaptions
        case noTimedWords

        var errorDescription: String? {
            switch self {
            case .noSource: "No audio clips to caption."
            case .noCaptions: "No caption clips to align."
            case .noTimedWords: "No timed words returned for caption alignment."
            }
        }
    }

    /// Text clips sharing this clip's caption group (so animation applies once for the whole
    /// caption track), or just the clip itself when it isn't part of a caption.
    func captionGroupTextClipIds(for clipId: String) -> [String] {
        guard let clip = clipFor(id: clipId), let group = clip.captionGroupId else { return [clipId] }
        let ids = captionGroupTextClipIds(groupId: group)
        return ids.isEmpty ? [clipId] : ids
    }

    /// Text clip ids in a caption group, in timeline order. Empty if the group has no text clips.
    func captionGroupTextClipIds(groupId: String) -> [String] {
        timeline.tracks.flatMap(\.clips)
            .filter { $0.captionGroupId == groupId && $0.mediaType == .text }.map(\.id)
    }

    func captionCanTranscribe(_ clip: Clip) -> Bool {
        guard clip.mediaType == .video || clip.mediaType == .audio else { return false }
        guard let asset = mediaAssets.first(where: { $0.id == clip.mediaRef }) else { return true }
        return asset.type == .audio || (asset.type == .video && asset.hasAudio)
    }

    func captionUsesVideoAudioExtraction(for clip: Clip) -> Bool {
        let assetType = mediaAssets.first(where: { $0.id == clip.mediaRef })?.type
        return assetType == .video || (assetType == nil && clip.mediaType == .video)
    }

    func captionTargets(ids: [String]) -> [Clip] {
        let pool: [Clip] = ids.isEmpty
            ? timeline.tracks.flatMap(\.clips)
            : ids.compactMap { findClip(id: $0).map { timeline.tracks[$0.trackIndex].clips[$0.clipIndex] } }
        return captionTargets(in: pool)
    }

    func captionTargets(trackIds: Set<String>) -> [Clip] {
        guard !trackIds.isEmpty else { return [] }
        let audioGroups = Set(timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .audio }.compactMap(\.linkGroupId))
        let pool = timeline.tracks
            .filter { trackIds.contains($0.id) }
            .flatMap(\.clips)
            .filter { !($0.mediaType == .video && $0.linkGroupId.map(audioGroups.contains) == true) }
        return captionTargets(in: pool)
    }

    private func captionTargets(in pool: [Clip]) -> [Clip] {
        let linkGroupsWithAudio = Set(pool.filter { $0.mediaType == .audio }.compactMap(\.linkGroupId))
        return pool
            .filter { clip in
                guard captionCanTranscribe(clip) else { return false }
                guard clip.mediaType == .video, let groupId = clip.linkGroupId else { return true }
                return !linkGroupsWithAudio.contains(groupId)
            }
            .sorted { $0.startFrame < $1.startFrame }
    }

    private struct CaptionTarget {
        let id: String
        let trackId: String
        let clip: Clip
    }

    @discardableResult
    func generateCaptions(for request: CaptionRequest) async throws -> [String] {
        let candidates = request.autoDetect ? captionTargets(ids: []) : captionTargets(ids: request.sourceClipIds)
        guard !candidates.isEmpty else { throw CaptionError.noSource }

        var targets = candidates.compactMap { c in
            findClip(id: c.id).map {
                CaptionTarget(id: c.id, trackId: timeline.tracks[$0.trackIndex].id, clip: timeline.tracks[$0.trackIndex].clips[$0.clipIndex])
            }
        }
        let results = try await transcribe(targets, request: request)

        if request.autoDetect {
            guard let winner = dominantSpeechTrack(targets, results) else { return [] }
            targets = targets.filter { $0.trackId == winner }
        }

        let specs = captionSpecs(targets, results: results, request: request)
        guard !specs.isEmpty else { return [] }
        return placeCaptionTrack(specs)
    }

    @discardableResult
    func alignCaptionsWithVolcengine(
        sourceClipIds: [String] = [],
        captionGroupId: String? = nil,
        captionClipIds: [String] = [],
        locale: Locale? = nil
    ) async throws -> [String] {
        let targets = captionTargets(ids: sourceClipIds)
        guard !targets.isEmpty else { throw CaptionError.noSource }
        let captionClips = captionAlignmentTargets(captionGroupId: captionGroupId, captionClipIds: captionClipIds)
        guard !captionClips.isEmpty else { throw CaptionError.noCaptions }

        var captionTargets = targets.compactMap { c in
            findClip(id: c.id).map {
                CaptionTarget(id: c.id, trackId: timeline.tracks[$0.trackIndex].id, clip: timeline.tracks[$0.trackIndex].clips[$0.clipIndex])
            }
        }
        let request = CaptionRequest(
            sourceClipIds: sourceClipIds,
            autoDetect: sourceClipIds.isEmpty,
            locale: locale,
            transcriptionProvider: .volcengine
        )
        let results = try await transcribe(captionTargets, request: request)
        if sourceClipIds.isEmpty, let winner = dominantSpeechTrack(captionTargets, results) {
            captionTargets = captionTargets.filter { $0.trackId == winner }
        }
        let words = timelineWords(captionTargets, results: results)
        guard !words.isEmpty else { throw CaptionError.noTimedWords }

        let plan = captionAlignmentPlan(captionClips: captionClips, words: words)
        guard !plan.isEmpty else { return [] }
        withTimelineSwap(actionName: "Align Captions") {
            var touchedTracks = Set<Int>()
            for ti in timeline.tracks.indices {
                for ci in timeline.tracks[ti].clips.indices {
                    let id = timeline.tracks[ti].clips[ci].id
                    guard let aligned = plan[id] else { continue }
                    var clip = timeline.tracks[ti].clips[ci]
                    clip.startFrame = aligned.startFrame
                    clip.setDuration(aligned.durationFrames)
                    clip.wordTimings = aligned.words
                    timeline.tracks[ti].clips[ci] = clip
                    touchedTracks.insert(ti)
                }
            }
            for index in touchedTracks {
                sortClips(trackIndex: index)
            }
            videoEngine?.refreshVisuals()
        }
        return captionClips.map(\.id).filter { plan[$0] != nil }
    }

    private func transcribe(_ targets: [CaptionTarget], request: CaptionRequest) async throws -> [String: TranscriptionResult] {
        var results: [String: TranscriptionResult] = [:]
        var firstError: Error?
        for t in targets where results[t.clip.mediaRef] == nil {
            do {
                guard let url = mediaResolver.resolveURL(for: t.clip.mediaRef) else { continue }
                let range = visibleSourceUnion(for: t.clip.mediaRef, in: targets)
                let isVideo = captionUsesVideoAudioExtraction(for: t.clip)
                if request.censorProfanity || request.locale != nil {
                    // option variants produce different transcripts — bypass the cache
                    results[t.clip.mediaRef] = isVideo
                        ? try await Transcription.transcribeVideoAudio(videoURL: url, censorProfanity: request.censorProfanity, preferredLocale: request.locale, sourceRange: range, provider: request.transcriptionProvider)
                        : try await Transcription.transcribe(fileURL: url, censorProfanity: request.censorProfanity, preferredLocale: request.locale, sourceRange: range, provider: request.transcriptionProvider)
                } else {
                    results[t.clip.mediaRef] = try await TranscriptCache.shared.transcript(
                        for: url,
                        isVideo: isVideo,
                        range: range,
                        provider: request.transcriptionProvider
                    )
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        if results.isEmpty, let firstError { throw firstError }
        return results
    }

    private func visibleSourceUnion(for mediaRef: String, in targets: [CaptionTarget]) -> ClosedRange<Double>? {
        let fps = Double(timeline.fps)
        let spans = targets.filter { $0.clip.mediaRef == mediaRef }.map { visibleSource($0.clip) }
        guard fps > 0, let lo = spans.map(\.start).min(), let hi = spans.map(\.end).max(), hi > lo else { return nil }
        let pad = 1.0
        return max(lo / fps - pad, 0)...(hi / fps + pad)
    }

    private func dominantSpeechTrack(_ targets: [CaptionTarget], _ results: [String: TranscriptionResult]) -> String? {
        var wordsByTrack: [String: Int] = [:]
        for t in targets {
            guard let result = results[t.clip.mediaRef] else { continue }
            wordsByTrack[t.trackId, default: 0] += spokenWordCount(in: t.clip, result)
        }
        return wordsByTrack.filter { $0.value > 0 }.max { $0.value < $1.value }?.key
    }

    private func captionSpecs(_ targets: [CaptionTarget], results: [String: TranscriptionResult], request: CaptionRequest) -> [TextClipSpec] {
        let fps = timeline.fps
        let groupId = UUID().uuidString

        var phrasesByClip: [String: [CaptionBuilder.Phrase]] = [:]
        for (ref, result) in results {
            let clips = targets.filter { $0.clip.mediaRef == ref }
            guard !clips.isEmpty else { continue }
            let phrases = result.segments.flatMap { seg in
                CaptionBuilder.phrases(
                    for: seg,
                    words: wordsIn(seg, result.words),
                    fits: { line in
                        if let maxCharacters = request.maxCharacters,
                           CaptionBuilder.visibleCharacterCount(line) > maxCharacters {
                            return false
                        }
                        return captionLineFits(line, style: request.style)
                    },
                    minDuration: AppTheme.Caption.minDisplayDuration,
                    maxCharacters: request.maxCharacters,
                    maxWords: request.maxWords
                )
            }
            for p in phrases {
                guard let owner = bestClip(for: p, among: clips) else { continue }
                phrasesByClip[owner.id, default: []].append(p)
            }
        }

        let animation: TextAnimation? = request.animation.isActive ? request.animation : nil
        return targets.flatMap { t -> [TextClipSpec] in
            guard let phrases = phrasesByClip[t.id] else { return [] }
            let cased = phrases.map { CaptionBuilder.Phrase(text: request.textCase.apply($0.text), start: $0.start, end: $0.end, words: $0.words) }
            let style = captionStyleFitting(cased.map(\.text), base: request.style)
            let transformFor = captionTransform(style: style, center: request.center)
            return CaptionBuilder.specs(for: cased, sourceClip: t.clip, trackIndex: 0, fps: fps, style: style, captionGroupId: groupId, animation: animation, transformFor: transformFor)
        }
    }

    // Words whose midpoint lands inside the segment, in transcript order.
    private func wordsIn(_ seg: TranscriptionSegment, _ words: [TranscriptionWord]) -> [TranscriptionWord] {
        words.filter { w in
            guard let s = w.start, let e = w.end else { return false }
            let mid = (s + e) / 2
            return mid >= seg.start && mid < seg.end
        }
    }

    // The clip with the most overlap owns the phrase
    private func bestClip(for p: CaptionBuilder.Phrase, among clips: [CaptionTarget]) -> CaptionTarget? {
        let ps = p.start * Double(timeline.fps), pe = p.end * Double(timeline.fps)
        func overlap(_ c: Clip) -> Double {
            let v = visibleSource(c)
            return max(0, min(pe, v.end) - max(ps, v.start))
        }
        guard let best = clips.max(by: { overlap($0.clip) < overlap($1.clip) }) else { return nil }
        let o = overlap(best.clip)
        return o > 0 && o >= (pe - ps) / 2 ? best : nil
    }

    private func spokenWordCount(in clip: Clip, _ result: TranscriptionResult) -> Int {
        let v = visibleSource(clip)
        let fps = Double(timeline.fps)
        return result.words.reduce(0) { count, w in
            guard let s = w.start, let e = w.end else { return count }
            let mid = (s + e) / 2 * fps
            return v.start <= mid && mid < v.end ? count + 1 : count
        }
    }

    private func visibleSource(_ c: Clip) -> (start: Double, end: Double) {
        let s = Double(c.trimStartFrame)
        return (s, s + Double(c.durationFrames) * max(c.speed, 0.0001))
    }

    private struct CaptionAlignmentTarget {
        let id: String
        let text: String
        let startFrame: Int
    }

    private struct TimelineCaptionWord {
        let text: String
        let startFrame: Int
        let endFrame: Int
    }

    private struct CaptionAlignment {
        let startFrame: Int
        let durationFrames: Int
        let words: [WordTiming]
    }

    private func captionAlignmentTargets(captionGroupId: String?, captionClipIds: [String]) -> [CaptionAlignmentTarget] {
        timeline.tracks.flatMap(\.clips)
            .filter { clip in
                guard clip.mediaType == .text else { return false }
                if !captionClipIds.isEmpty { return captionClipIds.contains(clip.id) }
                if let captionGroupId { return clip.captionGroupId == captionGroupId }
                return clip.captionGroupId != nil
            }
            .compactMap { clip in
                guard let text = clip.textContent?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return CaptionAlignmentTarget(id: clip.id, text: text, startFrame: clip.startFrame)
            }
            .sorted { $0.startFrame < $1.startFrame }
    }

    private func timelineWords(_ targets: [CaptionTarget], results: [String: TranscriptionResult]) -> [TimelineCaptionWord] {
        let fps = Double(timeline.fps)
        guard fps > 0 else { return [] }
        return targets.flatMap { target -> [TimelineCaptionWord] in
            guard let result = results[target.clip.mediaRef] else { return [] }
            let visible = visibleSource(target.clip)
            return result.words.compactMap { word in
                guard let start = word.start, let end = word.end, end > start else { return nil }
                let sourceStart = start * fps
                let sourceEnd = end * fps
                let midpoint = (sourceStart + sourceEnd) / 2
                guard midpoint >= visible.start, midpoint < visible.end else { return nil }
                let speed = max(target.clip.speed, 0.0001)
                let startFrame = target.clip.startFrame + Int(((sourceStart - visible.start) / speed).rounded())
                let endFrame = target.clip.startFrame + Int(((sourceEnd - visible.start) / speed).rounded())
                return TimelineCaptionWord(text: word.text, startFrame: max(target.clip.startFrame, startFrame), endFrame: max(startFrame + 1, min(target.clip.endFrame, endFrame)))
            }
        }
        .sorted { $0.startFrame < $1.startFrame }
    }

    private func captionAlignmentPlan(
        captionClips: [CaptionAlignmentTarget],
        words: [TimelineCaptionWord]
    ) -> [String: CaptionAlignment] {
        var plan: [String: CaptionAlignment] = [:]
        var cursor = 0
        for caption in captionClips {
            let tokens = alignmentTokens(caption.text)
            let tokenCount = max(1, tokens.count)
            let startIndex = bestAlignmentStart(tokens: tokens, words: words, cursor: cursor) ?? cursor
            guard startIndex < words.count else { break }
            let endIndex = alignmentEndIndex(from: startIndex, tokenCount: tokenCount, words: words)
            let slice = Array(words[startIndex...endIndex])
            guard let first = slice.first, let last = slice.last else { continue }
            let startFrame = max(0, first.startFrame)
            let endFrame = max(startFrame + 1, last.endFrame)
            plan[caption.id] = CaptionAlignment(
                startFrame: startFrame,
                durationFrames: endFrame - startFrame,
                words: slice.map {
                    WordTiming(
                        text: $0.text,
                        startFrame: max(0, $0.startFrame - startFrame),
                        endFrame: max(1, $0.endFrame - startFrame)
                    )
                }
            )
            cursor = min(words.count, endIndex + 1)
        }
        return plan
    }

    private func bestAlignmentStart(tokens: [String], words: [TimelineCaptionWord], cursor: Int) -> Int? {
        guard !tokens.isEmpty, cursor < words.count else { return nil }
        let upper = min(words.count, cursor + 80)
        var best: (index: Int, score: Int)?
        for index in cursor..<upper {
            let score = alignmentScore(tokens: tokens, words: words, start: index)
            guard score > 0 else { continue }
            if best == nil || score > best!.score {
                best = (index, score)
            }
            if score >= min(tokens.count, 3) {
                return index
            }
        }
        guard let best, best.score >= min(tokens.count, 2) else { return nil }
        return best.index
    }

    private func alignmentScore(tokens: [String], words: [TimelineCaptionWord], start: Int) -> Int {
        var probe: [String] = []
        var index = start
        while index < words.count, probe.count < tokens.count {
            let wordTokens = alignmentTokens(words[index].text)
            probe.append(contentsOf: wordTokens.isEmpty ? [words[index].text.lowercased()] : wordTokens)
            index += 1
        }
        var score = 0
        for pair in zip(tokens, probe) {
            guard pair.0 == pair.1 else { break }
            score += 1
        }
        return score
    }

    private func alignmentEndIndex(from start: Int, tokenCount: Int, words: [TimelineCaptionWord]) -> Int {
        var count = 0
        var index = start
        while index < words.count {
            count += max(1, alignmentTokens(words[index].text).count)
            if count >= tokenCount { return index }
            index += 1
        }
        return max(start, words.count - 1)
    }

    private func alignmentTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(current.lowercased())
            current = ""
        }
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if scalar.isCJK {
                flush()
                tokens.append(String(scalar))
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    func captionStyleFitting(_ texts: [String], base style: TextStyle) -> TextStyle {
        guard timeline.width > 0, timeline.height > 0 else { return style }
        let maxWidth = captionSafeMaxTextWidth
        let maxHeight = captionSafeMaxTextHeight
        guard maxWidth > .zero, maxHeight > .zero else { return style }

        var scale = AppTheme.Caption.maxPosition
        for text in texts where !text.isEmpty {
            let natural = TextLayout.naturalSize(
                content: text,
                style: style,
                maxWidth: maxWidth,
                canvasHeight: CGFloat(timeline.height)
            )
            if natural.width > maxWidth {
                scale = min(scale, Double(maxWidth / natural.width))
            }
            if natural.height > maxHeight {
                scale = min(scale, Double(maxHeight / natural.height))
            }
        }
        guard scale < AppTheme.Caption.maxPosition else { return style }

        var fitted = style
        fitted.fontScale = max(style.fontScale * scale, AppTheme.Caption.minGeneratedFontScale)
        return fitted
    }

    func captionTransform(for text: String, style: TextStyle, center: CGPoint) -> Transform {
        guard timeline.width > 0, timeline.height > 0 else {
            return Transform(center: (Double(center.x), Double(center.y)), width: AppTheme.Caption.maxPosition, height: AppTheme.Caption.maxPosition)
        }

        let canvasW = Double(timeline.width)
        let canvasH = Double(timeline.height)
        let natural = TextLayout.naturalSize(
            content: text,
            style: style,
            maxWidth: captionSafeMaxTextWidth,
            canvasHeight: CGFloat(timeline.height)
        )
        let width = min(Double(natural.width) / canvasW, Double(captionSafeWidthRatio))
        let height = min(Double(natural.height) / canvasH, Double(captionSafeHeightRatio))
        let minX = AppTheme.Caption.minPosition + Double(AppTheme.Caption.horizontalSafeInsetRatio)
        let maxX = AppTheme.Caption.maxPosition - Double(AppTheme.Caption.horizontalSafeInsetRatio)
        let minY = AppTheme.Caption.minPosition + Double(AppTheme.Caption.verticalSafeInsetRatio)
        let maxY = AppTheme.Caption.maxPosition - Double(AppTheme.Caption.verticalSafeInsetRatio)
        let centerX = clamped(Double(center.x), minX + width / 2, maxX - width / 2)
        let centerY = clamped(Double(center.y), minY + height / 2, maxY - height / 2)
        return Transform(center: (centerX, centerY), width: width, height: height)
    }

    private func captionTransform(style: TextStyle, center: CGPoint) -> (String) -> Transform? {
        { text in self.captionTransform(for: text, style: style, center: center) }
    }

    private func clamped(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), max(lower, upper))
    }

    private func placeCaptionTrack(_ specs: [TextClipSpec]) -> [String] {
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        let before = timeline
        undoManager?.disableUndoRegistration()
        timeline.tracks.insert(Track(type: .video), at: 0)
        let ids = placeTextClips(specs)
        undoManager?.enableUndoRegistration()
        guard !ids.isEmpty else {
            timeline = before
            videoEngine?.refreshVisuals()
            return []
        }
        registerTimelineSwap(undoState: before, redoState: timeline, actionName: "Generate Captions")
        notifyTimelineChanged()
        return ids
    }
}

private extension UnicodeScalar {
    var isCJK: Bool {
        (0x3400...0x4DBF).contains(Int(value)) ||
        (0x4E00...0x9FFF).contains(Int(value)) ||
        (0xF900...0xFAFF).contains(Int(value))
    }
}
