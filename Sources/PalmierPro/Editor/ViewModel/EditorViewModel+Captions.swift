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
        var provider: TranscriptionProvider = .local
        /// Animation applied to every generated caption clip (timed from the transcript).
        var animation: TextAnimation = TextAnimation()
    }

    enum CaptionCase: String, CaseIterable, Sendable {
        case auto, upper, lower

        var label: String {
            self == .auto ? "Auto" : fontCase.label
        }

        func apply(_ s: String) -> String {
            fontCase.apply(to: s)
        }

        private var fontCase: TextStyle.FontCase {
            switch self {
            case .auto: .mixed
            case .upper: .uppercase
            case .lower: .lowercase
            }
        }
    }

    enum CaptionError: LocalizedError {
        case noSource, timelineChanged

        var errorDescription: String? {
            switch self {
            case .noSource: "No audio clips to caption."
            case .timelineChanged: "The timeline changed while captions were being prepared. Generate captions again."
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
        let clips = timeline.tracks.flatMap(\.clips)
        let pool: [Clip]
        if ids.isEmpty {
            pool = clips
        } else {
            let selectedIds = Set(ids)
            pool = clips.filter { selectedIds.contains($0.id) }
        }
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
                if let group = multicamGroup(of: clip) {
                    return clip.mediaType == .audio && clip.mediaRef == group.master?.mediaRef
                }
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
    func generateCaptions(
        for request: CaptionRequest,
        applying mutation: (@MainActor (@MainActor () -> [String]) async throws -> [String])? = nil
    ) async throws -> [String] {
        let owningTimelineId = activeTimelineId
        var targets = resolvedCaptionTargets(for: request)
        guard !targets.isEmpty else { throw CaptionError.noSource }
        let results = try await transcribe(targets, request: request)

        guard timeline(for: owningTimelineId) != nil else { return [] }
        if activeTimelineId != owningTimelineId { activateTimeline(owningTimelineId) }
        targets = resolvedCaptionTargets(for: request)
        guard !targets.isEmpty else { throw CaptionError.noSource }

        let preparationTimeline = timeline

        if request.autoDetect {
            guard let winner = dominantSpeechTrack(targets, results) else { return [] }
            targets = targets.filter { $0.trackId == winner }
        }

        let animation: TextAnimation? = request.animation.isActive ? request.animation : nil
        let input = CaptionSpecBuilder.Input(
            targets: targets.compactMap { target in
                results[target.clip.mediaRef].map { CaptionSpecBuilder.Target(clip: target.clip, result: $0) }
            },
            fps: timeline.fps,
            canvasWidth: timeline.width,
            canvasHeight: timeline.height,
            style: request.style,
            center: request.center,
            textCase: request.textCase,
            maxWords: request.maxWords,
            animation: animation
        )
        let specs = try await CaptionSpecBuilder.build(input)
        try Task.checkCancellation()
        guard captionPreparationIsCurrent(
            timelineId: owningTimelineId,
            snapshot: preparationTimeline
        ) else {
            throw CaptionError.timelineChanged
        }
        guard !specs.isEmpty else { return [] }
        if let mutation {
            return try await mutation { self.placeCaptionTrack(specs) }
        }
        return placeCaptionTrack(specs)
    }

    // Estimate the cost of cloud transcription given the request. 0 if hit cache.
    func captionCloudCreditCost(for request: CaptionRequest) async -> Int {
        guard request.provider == .cloud else { return 0 }
        let targets = resolvedCaptionTargets(for: request)
        guard !targets.isEmpty else { return 0 }
        let targetClips = targets.map(\.clip)
        let language = CloudTranscription.languageIdentifier(request.locale)
        var seen: Set<String> = []
        var totalCost = 0
        for t in targets where seen.insert(t.clip.mediaRef).inserted {
            guard let url = mediaResolver.resolveURL(for: t.clip.mediaRef) else { continue }
            let range = CaptionTranscriptMapper.sourceUnion(for: t.clip.mediaRef, clips: targetClips, fps: timeline.fps)
            if await TranscriptCache.shared.hasCachedCloudTranscript(for: url, range: range, language: language) {
                continue
            }
            let seconds: Double
            if let range {
                seconds = max(0, range.upperBound - range.lowerBound)
            } else if let asset = mediaAssets.first(where: { $0.id == t.clip.mediaRef }) {
                seconds = max(0, asset.duration)
            } else {
                seconds = 0
            }
            totalCost += CostEstimator.estimatedTranscriptionCost(durationSeconds: seconds) ?? 0
        }
        return totalCost
    }

    private func resolvedCaptionTargets(for request: CaptionRequest) -> [CaptionTarget] {
        let candidates = request.autoDetect ? captionTargets(ids: []) : captionTargets(ids: request.sourceClipIds)
        return candidates.compactMap { c in
            findClip(id: c.id).map {
                CaptionTarget(id: c.id, trackId: timeline.tracks[$0.trackIndex].id, clip: timeline.tracks[$0.trackIndex].clips[$0.clipIndex])
            }
        }
    }

    func captionPreparationIsCurrent(
        timelineId: String,
        snapshot: Timeline
    ) -> Bool {
        activeTimelineId == timelineId && timeline == snapshot
    }

    private struct TranscribeJob {
        let mediaRef: String
        let url: URL
        let range: ClosedRange<Double>?
        let isVideo: Bool
    }

    private func transcribe(_ targets: [CaptionTarget], request: CaptionRequest) async throws -> [String: TranscriptionResult] {
        let targetClips = targets.map(\.clip)
        var seen: Set<String> = []
        let jobs: [TranscribeJob] = targets.compactMap { t in
            guard seen.insert(t.clip.mediaRef).inserted else { return nil }
            guard let url = mediaResolver.resolveURL(for: t.clip.mediaRef) else { return nil }
            let range = CaptionTranscriptMapper.sourceUnion(for: t.clip.mediaRef, clips: targetClips, fps: timeline.fps)
            return TranscribeJob(mediaRef: t.clip.mediaRef, url: url, range: range, isVideo: captionUsesVideoAudioExtraction(for: t.clip))
        }
        let projectId = projectId

        let outcomes = await withTaskGroup(of: (String, Result<TranscriptionResult, Error>).self) { group in
            for job in jobs {
                group.addTask {
                    do {
                        let result: TranscriptionResult
                        switch request.provider {
                        case .local:
                            if request.censorProfanity || request.locale != nil {
                                // option variants produce different transcripts — bypass the cache
                                result = job.isVideo
                                    ? try await Transcription.transcribeVideoAudio(videoURL: job.url, censorProfanity: request.censorProfanity, preferredLocale: request.locale, sourceRange: job.range)
                                    : try await Transcription.transcribe(fileURL: job.url, censorProfanity: request.censorProfanity, preferredLocale: request.locale, sourceRange: job.range)
                            } else {
                                result = try await TranscriptCache.shared.transcript(for: job.url, isVideo: job.isVideo, range: job.range)
                            }
                        case .cloud:
                            result = try await CloudTranscription.transcribe(
                                fileURL: job.url,
                                range: job.range,
                                preferredLocale: request.locale,
                                projectId: projectId
                            )
                        }
                        return (job.mediaRef, .success(result))
                    } catch {
                        return (job.mediaRef, .failure(error))
                    }
                }
            }
            var collected: [(String, Result<TranscriptionResult, Error>)] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        var results: [String: TranscriptionResult] = [:]
        var firstError: Error?
        for (mediaRef, outcome) in outcomes {
            switch outcome {
            case .success(let result): results[mediaRef] = result
            case .failure(let error): firstError = firstError ?? error
            }
        }
        if results.isEmpty, let firstError { throw firstError }
        return results
    }

    private func dominantSpeechTrack(_ targets: [CaptionTarget], _ results: [String: TranscriptionResult]) -> String? {
        var wordsByTrack: [String: Int] = [:]
        for t in targets {
            guard let result = results[t.clip.mediaRef] else { continue }
            wordsByTrack[t.trackId, default: 0] += CaptionTranscriptMapper.spokenWordCount(in: t.clip, result: result, fps: timeline.fps)
        }
        return wordsByTrack.filter { $0.value > 0 }.max { $0.value < $1.value }?.key
    }

    private func placeCaptionTrack(_ specs: [TextClipSpec]) -> [String] {
        undo.perform("Generate Captions") {
            let before = timeline
            let ids = undo.withoutRegistration {
                timeline.tracks.insert(Track(type: .video), at: 0)
                return placeTextClips(specs, clearExistingRegions: false, refreshVisuals: false)
            }
            guard !ids.isEmpty else {
                timeline = before
                videoEngine?.refreshVisuals()
                return []
            }
            registerTimelineSwap(undoState: before, redoState: timeline, actionName: "Generate Captions")
            notifyTimelineChanged(refreshVisuals: false)
            return ids
        }
    }
}
