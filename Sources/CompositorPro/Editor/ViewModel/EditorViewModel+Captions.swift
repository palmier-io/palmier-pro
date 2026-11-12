import CoreGraphics
import Foundation

extension EditorViewModel {
    struct CaptionRequest {
        var sourceClipIds: [String] = []
        var autoDetect: Bool = false
        var style: TextStyle = .caption
        var center: CGPoint = AppTheme.Caption.defaultCenter
        /// Destination platform. Owns caption width and clamps placement clear of its interface.
        var platform: DeliveryPlatform = .generic
        var textCase: CaptionCase = .auto
        var censorProfanity: Bool = false
        var locale: Locale? = nil
        var maxWords: Int? = nil
        var maxCharacters: Int? = nil
        var gapSettings: CaptionGapSettings = .default
        var provider: TranscriptionProvider = .local
        /// Animation applied to every generated caption clip (timed from the transcript).
        var animation: TextAnimation = TextAnimation()
    }

    struct TimelineTranscriptRow: Identifiable, Sendable, Equatable {
        let id: String
        let clipId: String
        let text: String
        let startFrame: Int
        let endFrame: Int

        var durationFrames: Int { endFrame - startFrame }
    }

    struct TimelineTranscriptDocument: Sendable {
        let fps: Int
        let rows: [TimelineTranscriptRow]
        let sourceTrackId: String?
        let sourceCaptionGroupId: String?
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
            case .timelineChanged: "The timeline changed while captions were being prepared. Try again."
            }
        }
    }

    /// Returns text clip ids in the clip's caption group, or the clip's id if none.
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

    /// For each clip id, returns all text clip ids in its caption group, or just the id itself if no group.
    /// Fast for large selections (O(timeline) instead of O(selection × timeline)).
    func captionGroupTextClipIds(expanding clipIds: [String]) -> [String] {
        let requested = Set(clipIds)
        var groupByRequestedId: [String: String] = [:]
        for track in timeline.tracks {
            for clip in track.clips where requested.contains(clip.id) {
                if let group = clip.captionGroupId { groupByRequestedId[clip.id] = group }
            }
        }
        let groups = Set(groupByRequestedId.values)

        var seen = Set<String>()
        var result: [String] = []
        var groupsWithText = Set<String>()
        for track in timeline.tracks {
            for clip in track.clips {
                let included: Bool
                if let group = clip.captionGroupId, groups.contains(group) {
                    included = clip.mediaType == .text
                    if included { groupsWithText.insert(group) }
                } else {
                    included = requested.contains(clip.id)
                }
                if included, seen.insert(clip.id).inserted { result.append(clip.id) }
            }
        }

        for id in clipIds where !seen.contains(id) {
            if let group = groupByRequestedId[id], groupsWithText.contains(group) { continue }
            if seen.insert(id).inserted { result.append(id) }
        }
        return result
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
        return captionTargets(
            in: pool,
            linkGroupsWithAudio: linkGroupsWithAudio(in: pool),
            allowAnyMulticamMic: !ids.isEmpty
        )
    }

    /// Targets for a clip scope explicitly named by an agent tool. Like any explicit selection,
    /// this may choose any multicam mic; it additionally rejects a linked video when its
    /// audio-side clip exists elsewhere on the timeline.
    func transcriptionTargets(clipIds: [String]) -> [Clip] {
        let clips = timeline.tracks.flatMap(\.clips)
        let selectedIds = Set(clipIds)
        let pool = clips.filter { selectedIds.contains($0.id) }
        return captionTargets(
            in: pool,
            linkGroupsWithAudio: linkGroupsWithAudio(in: clips),
            allowAnyMulticamMic: true
        )
    }

    func captionTargets(trackIds: Set<String>) -> [Clip] {
        guard !trackIds.isEmpty else { return [] }
        let clips = timeline.tracks.flatMap(\.clips)
        let pool = timeline.tracks
            .filter { trackIds.contains($0.id) }
            .flatMap(\.clips)
        return captionTargets(
            in: pool,
            linkGroupsWithAudio: linkGroupsWithAudio(in: clips),
            allowAnyMulticamMic: true
        )
    }

    private func linkGroupsWithAudio(in clips: [Clip]) -> Set<String> {
        Set(clips.filter { $0.mediaType == .audio }.compactMap(\.linkGroupId))
    }

    private func captionTargets(
        in pool: [Clip],
        linkGroupsWithAudio: Set<String>,
        allowAnyMulticamMic: Bool
    ) -> [Clip] {
        return pool
            .filter { clip in
                guard captionCanTranscribe(clip) else { return false }
                if let group = multicamGroup(of: clip) {
                    return clip.mediaType == .audio
                        && (allowAnyMulticamMic || clip.mediaRef == group.master?.mediaRef)
                }
                guard clip.mediaType == .video, let groupId = clip.linkGroupId else { return true }
                return !linkGroupsWithAudio.contains(groupId)
            }
            .sorted { $0.startFrame < $1.startFrame }
    }

    private struct CaptionTarget: Sendable {
        let id: String
        let trackId: String
        let clip: Clip
    }

    private struct PreparedTranscript: Sendable {
        let timelineId: String
        let timeline: Timeline
        let targets: [CaptionTarget]
        let results: [String: TranscriptionResult]
    }

    @discardableResult
    func generateCaptions(
        for request: CaptionRequest,
        applying mutation: (@MainActor (@MainActor () throws -> [String]) async throws -> [String])? = nil
    ) async throws -> [String] {
        try await projectPackageCoordinator.withIntent { lease in
            try await self.prepareAndPlaceCaptions(for: request, lease: lease, applying: mutation)
        }
    }

    private func prepareAndPlaceCaptions(
        for request: CaptionRequest,
        lease: ProjectPackageCoordinator.IntentLease,
        applying mutation: (@MainActor (@MainActor () throws -> [String]) async throws -> [String])?
    ) async throws -> [String] {
        let context = captionPreparationContext(for: request)
        let prepared = try await prepareTranscript(for: request)
        try context.validate(in: self)
        let targets = prepared.targets
        let results = prepared.results
        let preparationTimeline = prepared.timeline

        let animation: TextAnimation? = request.animation.isActive ? request.animation : nil
        let input = CaptionSpecBuilder.Input(
            targets: targets.compactMap { target in
                results[target.clip.mediaRef].map {
                    CaptionSpecBuilder.Target(
                        clip: target.clip,
                        result: $0
                    )
                }
            },
            fps: preparationTimeline.fps,
            timelineEndFrame: preparationTimeline.totalFrames,
            canvasWidth: preparationTimeline.width,
            canvasHeight: preparationTimeline.height,
            style: request.style,
            center: request.center,
            maxWidthRatio: request.platform.defaultCaptionPlacement().maxWidth,
            textCase: request.textCase,
            maxWords: request.maxWords,
            maxCharacters: request.maxCharacters,
            gapSettings: request.gapSettings,
            animation: animation
        )
        let specs = try await CaptionSpecBuilder.build(input)
        try context.validate(in: self)
        guard !specs.isEmpty else { return [] }
        try await context.checkSourcesAvailableOffMain(in: self)
        try context.validate(in: self)
        let place: @MainActor () throws -> [String] = {
            try self.projectPackageCoordinator.validate(lease)
            try context.validate(in: self)
            return self.placeCaptionTrack(specs, actionName: "Generate Captions")
        }
        if let mutation {
            return try await mutation(place)
        }
        return try place()
    }

    /// Places each subtitle asset's cues as one caption group on a new top track
    func placeCaptions(fromSubtitleAssets assets: [MediaAsset]) async {
        for asset in assets where asset.type == .subtitle {
            guard let url = mediaResolver.resolveURL(for: asset.id) else {
                mediaPanelToast = MediaPanelToast(message: L10n.string("Can't add captions — \"\(asset.name)\" is offline."))
                continue
            }
            do {
                try await importCaptions(from: url)
            } catch is CancellationError {
                return
            } catch {
                mediaPanelToast = MediaPanelToast(
                    message: L10n.string("Can't add captions from \"\(asset.name)\" — \(error.localizedDescription)")
                )
            }
        }
    }

    /// Parses a subtitle file into caption specs sized for the current timeline.
    /// A subtitle file carries no position, so placement is the platform's to decide rather than
    /// the file's to override. Text and timing still come from the file untouched.
    func subtitleCaptionSpecs(
        from url: URL, platform: DeliveryPlatform = .generic
    ) async throws -> [TextClipSpec] {
        let preparationTimeline = timeline
        let cues = try await SubtitleFileParser.parseFile(at: url)
        let placement = platform.defaultCaptionPlacement().clamped(into: platform.coveredArea)
        return try await CaptionSpecBuilder.build(
            cues: cues, fps: preparationTimeline.fps,
            canvasWidth: preparationTimeline.width, canvasHeight: preparationTimeline.height,
            style: .caption,
            center: CGPoint(x: CGFloat(placement.centerX), y: CGFloat(placement.centerY)),
            maxWidthRatio: placement.maxWidth
        )
    }

    /// Imports an SRT or WebVTT file as one caption group on a new top track. One undo step.
    @discardableResult
    func importCaptions(from url: URL, platform: DeliveryPlatform = .generic) async throws -> [String] {
        try await projectPackageCoordinator.withIntent { lease in
            let owningTimelineId = self.activeTimelineId
            let preparationTimeline = self.timeline
            let specs = try await self.subtitleCaptionSpecs(from: url, platform: platform)
            try Task.checkCancellation()
            try self.projectPackageCoordinator.validate(lease)
            guard self.captionPreparationIsCurrent(timelineId: owningTimelineId, snapshot: preparationTimeline) else {
                throw CaptionError.timelineChanged
            }
            return self.placeCaptionTrack(specs, actionName: "Add Captions")
        }
    }

    func timelineTranscript(
        for request: CaptionRequest
    ) async throws -> TimelineTranscriptDocument {
        try await projectPackageCoordinator.withIntent { lease in
            let context = self.captionPreparationContext(for: request)
            let prepared = try await self.prepareTranscript(for: request)
            try context.validate(in: self)
            let document = await Self.makeTimelineTranscriptDocument(prepared)
            try self.projectPackageCoordinator.validate(lease)
            try context.validate(in: self)
            return document
        }
    }

    func cachedTimelineTranscript() async -> TimelineTranscriptDocument? {
        let timelineId = activeTimelineId
        let snapshot = timeline
        var targets = resolvedCaptionTargets(for: CaptionRequest(autoDetect: true))
        guard !targets.isEmpty else { return nil }
        let clips = targets.map(\.clip)
        for provider in [TranscriptionProvider.cloud, .local] {
            var seen: Set<String> = []
            var results: [String: TranscriptionResult] = [:]
            var complete = true
            for target in targets where seen.insert(target.clip.mediaRef).inserted {
                guard !Task.isCancelled,
                      let url = mediaResolver.expectedURL(for: target.clip.mediaRef) else {
                    return nil
                }
                let range = CaptionTranscriptMapper.sourceUnion(
                    for: target.clip.mediaRef,
                    clips: clips,
                    fps: snapshot.fps
                )
                let cached = provider == .cloud
                    ? await TranscriptCache.shared.cachedCloudTranscript(
                        for: url, range: range, language: nil
                    )
                    : await TranscriptCache.shared.cachedTranscript(for: url, range: range)
                guard let cached else {
                    complete = false
                    break
                }
                results[target.clip.mediaRef] = cached
            }
            guard complete else { continue }
            guard !Task.isCancelled,
                  activeTimelineId == timelineId,
                  timeline == snapshot,
                  let winner = dominantSpeechTrack(targets, results) else {
                return nil
            }
            targets = targets.filter { $0.trackId == winner }
            return await Self.makeTimelineTranscriptDocument(PreparedTranscript(
                timelineId: timelineId,
                timeline: snapshot,
                targets: targets,
                results: results
            ))
        }
        return nil
    }

    @concurrent
    private static func makeTimelineTranscriptDocument(
        _ prepared: PreparedTranscript
    ) async -> TimelineTranscriptDocument {
        let rows = prepared.targets.flatMap { target -> [TimelineTranscriptRow] in
            guard let result = prepared.results[target.clip.mediaRef] else { return [] }
            let phrases = CaptionTranscriptMapper.phrases(
                for: target.clip,
                result: result,
                fps: prepared.timeline.fps,
                maxWords: nil,
                maxCharacters: nil,
                fits: { _ in true }
            )
            return CaptionBuilder.specs(
                for: phrases,
                sourceClip: target.clip,
                trackIndex: 0,
                fps: prepared.timeline.fps,
                style: .caption,
                captionGroupId: nil
            ).enumerated().map { index, spec in
                TimelineTranscriptRow(
                    id: "\(target.clip.id):\(index):\(spec.startFrame)",
                    clipId: target.clip.id,
                    text: spec.content,
                    startFrame: spec.startFrame,
                    endFrame: spec.startFrame + spec.durationFrames
                )
            }
        }
        .sorted { ($0.startFrame, $0.id) < ($1.startFrame, $1.id) }
        return TimelineTranscriptDocument(
            fps: prepared.timeline.fps,
            rows: rows,
            sourceTrackId: nil,
            sourceCaptionGroupId: nil
        )
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

    private func prepareTranscript(
        for request: CaptionRequest
    ) async throws -> PreparedTranscript {
        let timelineId = activeTimelineId
        let timelineSnapshot = timeline
        var targets = resolvedCaptionTargets(for: request)
        guard !targets.isEmpty else { throw CaptionError.noSource }
        let results = try await transcribe(targets, request: request)
        try Task.checkCancellation()
        guard activeTimelineId == timelineId, timeline == timelineSnapshot else {
            throw CaptionError.timelineChanged
        }
        if request.autoDetect {
            targets = dominantSpeechTrack(targets, results)
                .map { winner in targets.filter { $0.trackId == winner } }
                ?? []
        }
        return PreparedTranscript(
            timelineId: timelineId,
            timeline: timelineSnapshot,
            targets: targets,
            results: results
        )
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

    @MainActor struct CaptionPreparationContext {
        struct Source {
            let asset: MediaAsset
            let preparation: MediaAsset.PreparationContext
            // Manifest-derived URL only; existence is checked off-main (see below).
            let expectedURL: URL?
            let duration: Double
            let hasAudio: Bool
        }

        let timelineId: String
        let timeline: Timeline
        let projectId: String?
        let sources: [Source]

        func validate(in editor: EditorViewModel) throws {
            try Task.checkCancellation()
            guard editor.projectId == projectId,
                  editor.captionPreparationIsCurrent(timelineId: timelineId, snapshot: timeline),
                  sources.allSatisfy({ source in
                      editor.mediaAssetsById[source.asset.id] === source.asset
                          && source.asset.preparationContext == source.preparation
                          && source.asset.duration == source.duration
                          && source.asset.hasAudio == source.hasAudio
                          && editor.mediaResolver.expectedURL(for: source.asset.id) == source.expectedURL
                  }) else { throw CaptionError.timelineChanged }
        }

        // File availability is disk I/O; run it on the coordinator queue, never the main actor.
        func checkSourcesAvailableOffMain(in editor: EditorViewModel) async throws {
            let urls = sources.compactMap(\.expectedURL)
            guard !urls.isEmpty else { return }
            let available = try await editor.projectPackageCoordinator.io.perform {
                let fm = FileManager.default
                return urls.allSatisfy { fm.fileExists(atPath: $0.path) }
            }
            try Task.checkCancellation()
            guard available else { throw CaptionError.timelineChanged }
        }
    }

    func captionPreparationContext(for request: CaptionRequest) -> CaptionPreparationContext {
        let ids = Set(resolvedCaptionTargets(for: request).map(\.clip.mediaRef))
        return CaptionPreparationContext(
            timelineId: activeTimelineId, timeline: timeline, projectId: projectId,
            sources: ids.compactMap { id in
                mediaAssetsById[id].map { asset in
                    CaptionPreparationContext.Source(
                        asset: asset, preparation: asset.preparationContext,
                        expectedURL: mediaResolver.expectedURL(for: id), duration: asset.duration, hasAudio: asset.hasAudio
                    )
                }
            }
        )
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
        let service = captionTranscriptionService

        let outcomes = await withTaskGroup(of: (String, Result<TranscriptionResult, Error>).self) { group in
            for job in jobs {
                group.addTask {
                    do {
                        let result = try await service.load(.init(
                            url: job.url, isVideo: job.isVideo, range: job.range,
                            censorProfanity: request.censorProfanity, locale: request.locale,
                            provider: request.provider, projectId: projectId
                        ))
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
        try Task.checkCancellation()

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

    /// Nested inside an open undo transaction this coalesces into the outer group.
    @discardableResult
    func placeCaptionTrack(_ specs: [TextClipSpec], actionName: String) -> [String] {
        undo.perform(actionName) {
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
            registerTimelineSwap(undoState: before, redoState: timeline, actionName: actionName)
            notifyTimelineChanged(refreshVisuals: false)
            return ids
        }
    }
}
