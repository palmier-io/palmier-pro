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
        var maxWords: Int? = nil
        /// Animation applied to every generated caption clip (timed from the transcript).
        var animation: TextAnimation = TextAnimation()
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
        return size.width <= CGFloat(timeline.width) * AppTheme.ComponentSize.captionPreviewMaxTextWidthRatio
    }

    enum CaptionError: LocalizedError {
        case noSource

        var errorDescription: String? {
            switch self {
            case .noSource: "No audio clips to caption."
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
                        ? try await Transcription.transcribeVideoAudio(videoURL: url, censorProfanity: request.censorProfanity, preferredLocale: request.locale, sourceRange: range)
                        : try await Transcription.transcribe(fileURL: url, censorProfanity: request.censorProfanity, preferredLocale: request.locale, sourceRange: range)
                } else {
                    results[t.clip.mediaRef] = try await TranscriptCache.shared.transcript(for: url, isVideo: isVideo, range: range)
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
        let transformFor = captionTransform(style: request.style, center: request.center)

        var phrasesByClip: [String: [CaptionBuilder.Phrase]] = [:]
        for (ref, result) in results {
            let clips = targets.filter { $0.clip.mediaRef == ref }
            guard !clips.isEmpty else { continue }
            let phrases = result.segments.flatMap { seg in
                CaptionBuilder.phrases(
                    for: seg,
                    words: wordsIn(seg, result.words),
                    fits: { captionLineFits($0, style: request.style) },
                    maxWords: request.maxWords,
                    minDuration: AppTheme.Caption.minDisplayDuration
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
            return CaptionBuilder.specs(for: cased, sourceClip: t.clip, trackIndex: 0, fps: fps, style: request.style, captionGroupId: groupId, animation: animation, transformFor: transformFor)
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

    private func captionTransform(style: TextStyle, center: CGPoint) -> (String) -> Transform? {
        let canvasW = Double(timeline.width), canvasH = Double(timeline.height)
        return { text in
            let natural = TextLayout.naturalSize(
                content: text, style: style, maxWidth: CGFloat(canvasW) * AppTheme.ComponentSize.captionPreviewMaxTextWidthRatio, canvasHeight: CGFloat(canvasH)
            )
            return Transform(
                center: (Double(center.x), Double(center.y)),
                width: Double(natural.width) / canvasW,
                height: Double(natural.height) / canvasH
            )
        }
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
