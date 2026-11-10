import AVFoundation
import Foundation

struct AudioFinishingError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

extension EditorViewModel {
    typealias AudioLoudnessAnalysis = @Sendable (URL, String, CMTimeRange) async throws -> LoudnessMeasurement

    struct ClipFinishingSnapshot: Sendable, Equatable {
        let id: String
        let mediaRef: String
        let startFrame: Int
        let durationFrames: Int
        let trimStartFrame: Int
        let trimEndFrame: Int
        let speed: Double
        let speedTrack: KeyframeTrack<Double>?
        let volume: Double
        let effects: [Effect]?
        let sourceURL: URL
        let sourceVersion: LoudnessAnalyzer.SourceVersion
    }

    struct TimelineFinishingSnapshot: Sendable {
        let timelineId: String
        let revision: Int
        let fps: Int
        let clips: [String: ClipFinishingSnapshot]
    }

    func resetAnalysisSessionState() {
        for task in enhancementJobTasks.values { task.cancel() }
        enhancementJobTasks.removeAll()
        for id in enhancementJobs.keys {
            if enhancementJobs[id]?.status == .running || enhancementJobs[id]?.status == .queued {
                enhancementJobs[id]?.status = .cancelled
                enhancementJobs[id]?.stage = .cancelled
            }
        }
        denoiseFailed.removeAll()
        breathFailed.removeAll()
        deessFailed.removeAll()
        enhancementJobFingerprints.removeAll()
        loudnessInFlight.removeAll()
        mediaVisualCache.resetSessionState()
        for id in openTimelineIds { videoEngine?.evictComposition(for: id) }
        videoEngine?.rebuild()
    }

    // MARK: - Enhancement job management

    private func enhancementFingerprint(
        clipIds: Set<String>, type: EnhancementJob.JobType, params: EnhancementJob.JobParams
    ) -> String {
        let clips = clipIds.compactMap { clipFor(id: $0) }.sorted { $0.id < $1.id }
        let clipDetails = clips.map {
            "\($0.id):\($0.mediaRef):\($0.startFrame):\($0.durationFrames):\($0.trimStartFrame):\($0.trimEndFrame):\($0.speed)"
        }.joined(separator: ";")
        let versions = clips.compactMap { clip -> String? in
            guard let url = mediaResolver.expectedURL(for: clip.mediaRef) else { return nil }
            return (try? LoudnessAnalyzer.SourceVersion(url))?.url
        }.joined(separator: ",")
        let paramStr = "\(params.amount ?? 0)-\(params.deess ?? 0)-\(params.targetLUFS ?? 0)-\(params.enabled)"
        return "\(timeline.id)|\(type.rawValue)|\(clipDetails)|\(versions)|\(paramStr)"
    }

    private func existingJob(fingerprint: String) -> EnhancementJob? {
        guard let jobId = enhancementJobFingerprints[fingerprint],
              let job = enhancementJobs[jobId],
              job.status == .queued || job.status == .running else { return nil }
        return job
    }

    @discardableResult
    func startEnhancementJob(
        clipIds: Set<String>,
        type: EnhancementJob.JobType,
        params: EnhancementJob.JobParams,
        actionName: String,
        analyze: AudioLoudnessAnalysis? = nil
    ) async throws -> (UUID, Bool) {
        guard !projectPackageCoordinator.isClosing else {
            throw AudioFinishingError(reason: "Project is closing.")
        }
        let clips = clipIds.compactMap { clipFor(id: $0) }
        guard clips.count == clipIds.count else { throw AudioFinishingError(reason: "One or more clips not found.") }
        guard clips.allSatisfy({ $0.mediaType == .audio && $0.sourceClipType != .sequence }) else {
            throw AudioFinishingError(reason: "Enhancement only supports non-nested audio clips.")
        }
        let urls = mediaResolver.expectedURLMap()
        let missingRefs = clips.compactMap { clip in
            missingMediaRefs.contains(clip.mediaRef) || urls[clip.mediaRef] == nil ? clip.mediaRef : nil
        }
        guard missingRefs.isEmpty else {
            throw AudioFinishingError(reason: "Missing media for: \(missingRefs.joined(separator: ", "))")
        }
        if type == .denoise || type == .enhance {
            try AudioEnhancer.availability.requireAvailable()
        }

        var versions: [String: LoudnessAnalyzer.SourceVersion] = [:]
        var clipSnapshots: [String: ClipFinishingSnapshot] = [:]
        for clip in clips {
            guard let url = urls[clip.mediaRef] else { continue }
            let version = try LoudnessAnalyzer.SourceVersion(url)
            versions[clip.mediaRef] = version
            clipSnapshots[clip.id] = ClipFinishingSnapshot(
                id: clip.id, mediaRef: clip.mediaRef,
                startFrame: clip.startFrame, durationFrames: clip.durationFrames,
                trimStartFrame: clip.trimStartFrame, trimEndFrame: clip.trimEndFrame,
                speed: clip.speed, speedTrack: clip.speedTrack,
                volume: clip.volume, effects: clip.effects,
                sourceURL: url, sourceVersion: version
            )
        }

        let snapshot = TimelineFinishingSnapshot(
            timelineId: timeline.id,
            revision: timelineRenderRevision,
            fps: timeline.fps,
            clips: clipSnapshots
        )

        let fingerprint = enhancementFingerprint(clipIds: clipIds, type: type, params: params)
        if let existing = existingJob(fingerprint: fingerprint) {
            return (existing.id, false)
        }

        for existing in enhancementJobs.values where (existing.status == .queued || existing.status == .running) && !existing.clipIds.isDisjoint(with: clipIds) {
            cancelEnhancementJob(existing.id)
        }

        if type == .loudness || type == .enhance {
            loudnessInFlight.formUnion(clipIds)
        }

        let job = EnhancementJob(
            id: UUID(),
            clipIds: clipIds,
            mediaRefs: Set(clips.map(\.mediaRef)),
            type: type,
            params: params,
            sourceVersions: versions,
            startedAt: Date(),
            completedAt: nil,
            status: .queued,
            stage: .queued,
            errors: [],
            warnings: [],
            changedClipIds: [],
            timelineId: timeline.id,
            timelineRevision: timelineRenderRevision
        )
        enhancementJobs[job.id] = job
        enhancementJobFingerprints[fingerprint] = job.id

        let jobId = job.id
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.runEnhancementJob(jobId: jobId, snapshot: snapshot, actionName: actionName, customAnalyze: analyze)
        }
        enhancementJobTasks[jobId] = task
        return (jobId, true)
    }

    private func runEnhancementJob(
        jobId: UUID,
        snapshot: TimelineFinishingSnapshot,
        actionName: String,
        customAnalyze: AudioLoudnessAnalysis?
    ) async {
        updateJobStatus(jobId, status: .running, stage: .analyzing)
        do {
            try Task.checkCancellation()
            let job = try await getJob(jobId)
            let urls = mediaResolver.expectedURLMap()
            let missing = missingMediaRefs

            try revalidateSnapshot(snapshot)

            var stageWarnings: [String] = []
            var replacements: [String: Clip] = [:]

            switch job.type {
            case .denoise:
                for clipSnap in snapshot.clips.values {
                    try Task.checkCancellation()
                    _ = try await AudioEnhancer.denoisedAudio(for: clipSnap.sourceURL, mediaRef: clipSnap.mediaRef)
                }
                for (id, _) in snapshot.clips {
                    guard var clip = clipFor(id: id) else { continue }
                    var stack = clip.effects ?? []
                    let amount = job.params.amount ?? Clip.defaultDenoiseAmount
                    if let i = stack.firstIndex(where: { $0.type == Clip.denoiseEffectType }) {
                        stack[i].enabled = true
                        stack[i].params["amount"] = EffectParam(value: amount)
                    } else {
                        stack.append(Effect(type: Clip.denoiseEffectType, enabled: true, params: ["amount": EffectParam(value: amount)]))
                    }
                    clip.effects = stack
                    replacements[id] = clip
                }

            case .debreath:
                for clipSnap in snapshot.clips.values {
                    try Task.checkCancellation()
                    _ = try await BreathDetector.analysis(for: clipSnap.sourceURL, mediaRef: clipSnap.mediaRef)
                }
                for (id, _) in snapshot.clips {
                    guard var clip = clipFor(id: id) else { continue }
                    var stack = clip.effects ?? []
                    let amount = job.params.amount ?? Clip.defaultDebreathAmount
                    if let i = stack.firstIndex(where: { $0.type == Clip.debreathEffectType }) {
                        stack[i].enabled = true
                        stack[i].params["amount"] = EffectParam(value: amount)
                    } else {
                        stack.append(Effect(type: Clip.debreathEffectType, enabled: true, params: ["amount": EffectParam(value: amount)]))
                    }
                    clip.effects = stack
                    replacements[id] = clip
                }

            case .enhance:
                let clips = snapshot.clips.values.compactMap { clipFor(id: $0.id) }
                let prepTimeline = Timeline(fps: snapshot.fps, width: timeline.width, height: timeline.height,
                                            tracks: [Track(id: UUID().uuidString, type: .audio, clips: clips)])
                let prepared = try await PreparedAudio.prepare(
                    timeline: prepTimeline, resolveTimeline: { _ in nil },
                    resolveURL: { urls[$0] }, missingMediaRefs: missing
                )
                for ref in job.mediaRefs {
                    if prepared.denoisedURLs[ref] == nil { stageWarnings.append("Denoising unavailable for \(ref)") }
                    if prepared.breaths[ref] == nil { stageWarnings.append("Breath detection unavailable for \(ref)") }
                    if prepared.sibilance[ref] == nil { stageWarnings.append("De-ess analysis unavailable for \(ref)") }
                }

                var targets: [AudioLoudnessTarget] = []
                for clipSnap in snapshot.clips.values {
                    guard let clip = clipFor(id: clipSnap.id) else { continue }
                    let range = try LoudnessAnalyzer.sourceRange(for: clip, fps: snapshot.fps)
                    targets.append(AudioLoudnessTarget(id: clip.id, mediaRef: clip.mediaRef, url: clipSnap.sourceURL, range: range))
                }
                let analyze = customAnalyze ?? { url, ref, range in
                    try await LoudnessAnalyzer.integratedLoudness(for: url, mediaRef: ref, range: range)
                }
                let measured = try await Self.measureAudio(targets, targetLUFS: -16, analyze: analyze)
                stageWarnings.append(contentsOf: measured.warnings)

                for (id, _) in snapshot.clips {
                    guard var clip = clipFor(id: id) else { continue }
                    Self.configureEnhancement(&clip, enabled: true, amount: job.params.amount, deess: job.params.deess)
                    if let gain = measured.gains[id] {
                        Self.setAudioEffect(&clip, type: Clip.loudnessEffectType, enabled: true, values: ["gainDB": gain])
                    }
                    replacements[id] = clip
                }

            case .loudness:
                var targets: [AudioLoudnessTarget] = []
                for clipSnap in snapshot.clips.values {
                    guard let clip = clipFor(id: clipSnap.id) else { continue }
                    let range = try LoudnessAnalyzer.sourceRange(for: clip, fps: snapshot.fps)
                    targets.append(AudioLoudnessTarget(id: clip.id, mediaRef: clip.mediaRef, url: clipSnap.sourceURL, range: range))
                }
                let analyze = customAnalyze ?? { url, ref, range in
                    try await LoudnessAnalyzer.integratedLoudness(for: url, mediaRef: ref, range: range)
                }
                let measured = try await Self.measureAudio(targets, targetLUFS: job.params.targetLUFS ?? -16, analyze: analyze)
                stageWarnings.append(contentsOf: measured.warnings)

                for (id, _) in snapshot.clips {
                    guard var clip = clipFor(id: id) else { continue }
                    if let gain = measured.gains[id] {
                        Self.setAudioEffect(&clip, type: Clip.loudnessEffectType, enabled: true, values: ["gainDB": gain])
                    }
                    replacements[id] = clip
                }
            }

            try Task.checkCancellation()
            updateJobStatus(jobId, stage: .applying)

            let changedIds = try await projectPackageCoordinator.withMutation { _ -> [String] in
                try Task.checkCancellation()
                try revalidateSnapshot(snapshot)

                let changed = snapshot.clips.keys.filter { clipFor(id: $0) != replacements[$0] }
                if !changed.isEmpty {
                    mutateClips(ids: Set(changed), actionName: actionName) { clip in
                        if let rep = replacements[clip.id] { clip = rep }
                    }
                }
                return changed
            }

            for id in changedIds { appendChanged(jobId, id) }
            for warning in stageWarnings { appendWarning(jobId, warning) }
            finishJob(jobId, success: true)
        } catch is CancellationError {
            finishJob(jobId, success: false, error: "Cancelled")
        } catch {
            finishJob(jobId, success: false, error: error.localizedDescription)
        }
    }

    private func revalidateSnapshot(_ snapshot: TimelineFinishingSnapshot) throws {
        guard !projectPackageCoordinator.isClosing else {
            throw AudioFinishingError(reason: "Project is closing.")
        }
        guard timeline.id == snapshot.timelineId else {
            throw AudioFinishingError(reason: "Timeline switched during audio finishing. Retry with the current timeline.")
        }
        let urls = mediaResolver.expectedURLMap()
        for (clipId, clipSnap) in snapshot.clips {
            guard let currentClip = clipFor(id: clipId) else {
                throw AudioFinishingError(reason: "Clip '\(clipId)' was removed during audio finishing.")
            }
            guard currentClip.mediaRef == clipSnap.mediaRef,
                  currentClip.startFrame == clipSnap.startFrame,
                  currentClip.durationFrames == clipSnap.durationFrames,
                  currentClip.trimStartFrame == clipSnap.trimStartFrame,
                  currentClip.trimEndFrame == clipSnap.trimEndFrame,
                  currentClip.speed == clipSnap.speed,
                  currentClip.speedTrack == clipSnap.speedTrack else {
                throw AudioFinishingError(reason: "Clip '\(clipId)' timing or source range changed during audio finishing.")
            }
            guard currentClip.volume == clipSnap.volume,
                  currentClip.effects == clipSnap.effects else {
                throw AudioFinishingError(reason: "Clip '\(clipId)' settings changed during audio finishing.")
            }
            guard let url = urls[clipSnap.mediaRef], url == clipSnap.sourceURL else {
                throw AudioFinishingError(reason: "Source URL for clip '\(clipId)' changed during audio finishing.")
            }
            let currentVersion = try LoudnessAnalyzer.SourceVersion(url)
            guard currentVersion == clipSnap.sourceVersion else {
                throw AudioFinishingError(reason: "Source media for clip '\(clipId)' was modified during audio finishing.")
            }
        }
    }

    private func getJob(_ id: UUID) async throws -> EnhancementJob {
        guard let job = enhancementJobs[id] else { throw AudioFinishingError(reason: "Job not found: \(id)") }
        return job
    }

    @MainActor
    private func updateJobStatus(_ id: UUID, status: EnhancementJob.Status? = nil, stage: EnhancementJob.Stage? = nil) {
        guard var job = enhancementJobs[id] else { return }
        if let status { job.status = status }
        if let stage { job.stage = stage }
        enhancementJobs[id] = job
    }

    @MainActor
    private func appendWarning(_ id: UUID, _ warning: String) {
        guard var job = enhancementJobs[id] else { return }
        job.warnings.append(warning)
        enhancementJobs[id] = job
    }

    @MainActor
    private func appendChanged(_ id: UUID, _ clipId: String) {
        guard var job = enhancementJobs[id], !clipId.isEmpty else { return }
        job.changedClipIds.insert(clipId)
        enhancementJobs[id] = job
    }

    @MainActor
    private func finishJob(_ id: UUID, success: Bool, error: String? = nil) {
        enhancementJobTasks.removeValue(forKey: id)
        guard var job = enhancementJobs[id] else { return }
        job.completedAt = Date()
        if job.type == .loudness || job.type == .enhance {
            loudnessInFlight.subtract(job.clipIds)
        }
        if let error {
            if error == "Cancelled" || job.status == .cancelled {
                job.status = .cancelled
                job.stage = .cancelled
            } else {
                job.errors.append(error)
                job.status = .failed
                job.stage = .failed
            }
        } else {
            job.status = success ? .completed : .failed
            job.stage = success ? .completed : .failed
        }
        enhancementJobs[id] = job
        let fingerprint = enhancementFingerprint(clipIds: job.clipIds, type: job.type, params: job.params)
        removeFingerprint(fingerprint)
    }

    @MainActor
    func removeFingerprint(_ fingerprint: String) {
        enhancementJobFingerprints.removeValue(forKey: fingerprint)
    }

    func cancelEnhancementJob(_ id: UUID) {
        enhancementJobTasks[id]?.cancel()
        enhancementJobTasks.removeValue(forKey: id)
        guard var job = enhancementJobs[id] else { return }
        if job.type == .loudness || job.type == .enhance {
            loudnessInFlight.subtract(job.clipIds)
        }
        job.completedAt = Date()
        job.status = .cancelled
        job.stage = .cancelled
        enhancementJobs[id] = job
        let fingerprint = enhancementFingerprint(clipIds: job.clipIds, type: job.type, params: job.params)
        removeFingerprint(fingerprint)
    }

    func getEnhancementJobStatus(_ id: UUID) -> (status: String, stage: String, errors: [String], warnings: [String], changed: [String], progress: Double)? {
        guard let job = enhancementJobs[id] else { return nil }
        let progress: Double = {
            switch job.stage {
            case .queued: return 0
            case .analyzing: return 0.3
            case .applying: return 0.7
            case .completed, .failed, .cancelled: return 1.0
            }
        }()
        return (job.status.rawValue, job.stage.rawValue, job.errors, job.warnings, Array(job.changedClipIds), progress)
    }

    func getAllEnhancementJobs() -> [(id: UUID, type: String, status: String, clipCount: Int, progress: Double)] {
        let jobs = enhancementJobs.values.map { job -> (id: UUID, type: String, status: String, clipCount: Int, progress: Double, startedAt: Date) in
            let progress: Double = {
                switch job.stage {
                case .queued: return 0
                case .analyzing: return 0.3
                case .applying: return 0.7
                case .completed, .failed, .cancelled: return 1.0
                }
            }()
            return (job.id, job.type.rawValue, job.status.rawValue, job.clipIds.count, progress, job.startedAt)
        }
        return jobs.sorted { $0.startedAt < $1.startedAt }.map { ($0.id, $0.type, $0.status, $0.clipCount, $0.progress) }
    }

    @discardableResult
    func awaitEnhancementJob(_ id: UUID) async throws -> EnhancementJob {
        let jobTask = enhancementJobTasks[id]
        await withTaskCancellationHandler {
            await jobTask?.value
        } onCancel: { [self] in
            // The handler runs off the actor, so the cancellation hops back to the main actor.
            Task { @MainActor in cancelEnhancementJob(id) }
        }
        guard let job = enhancementJobs[id] else {
            throw AudioFinishingError(reason: "Job not found: \(id)")
        }
        if job.status == .cancelled || Task.isCancelled {
            throw CancellationError()
        }
        if job.status == .failed {
            let errorMsg = job.errors.isEmpty ? "Enhancement failed." : job.errors.joined(separator: "; ")
            throw AudioFinishingError(reason: errorMsg)
        }
        return job
    }

    @discardableResult
    func awaitEnhancementJobsForClips(_ clipIds: Set<String>) async throws -> [String] {
        var allWarnings: [String] = []
        let matchingJobs = enhancementJobs.values.filter { job in
            !job.clipIds.isDisjoint(with: clipIds) && (job.status == .queued || job.status == .running)
        }
        for job in matchingJobs {
            try Task.checkCancellation()
            let completed = try await awaitEnhancementJob(job.id)
            allWarnings.append(contentsOf: completed.warnings)
        }
        return allWarnings
    }

    @discardableResult
    func awaitEnhancementJobsForTimeline(_ timeline: Timeline) async throws -> [String] {
        let resolve = timelineResolver()
        let audibleClips = PreparedAudio.audibleClips(timeline: timeline, resolveTimeline: resolve)
        guard !audibleClips.isEmpty else { return [] }
        return try await awaitEnhancementJobsForClips(Set(audibleClips.map(\.id)))
    }

    func setDenoise(clipIds: Set<String>, enabled: Bool, amount: Double? = nil, actionName: String) throws {
        if enabled { try AudioEnhancer.availability.requireAvailable() }
        let clamped = amount.map { min(1, max(0, $0)) }
        mutateClips(ids: clipIds, actionName: actionName) { clip in
            var stack = clip.effects ?? []
            if let i = stack.firstIndex(where: { $0.type == Clip.denoiseEffectType }) {
                stack[i].enabled = enabled
                if let clamped { stack[i].params["amount"] = EffectParam(value: clamped) }
            } else if enabled {
                stack.append(Effect(type: Clip.denoiseEffectType, enabled: true, params: [
                    "amount": EffectParam(value: clamped ?? Clip.defaultDenoiseAmount),
                ]))
            }
            clip.effects = stack.isEmpty ? nil : stack
        }
    }

    func setDebreath(clipIds: Set<String>, enabled: Bool, amount: Double? = nil, actionName: String) {
        let clamped = amount.map { min(1, max(0, $0)) }
        mutateClips(ids: clipIds, actionName: actionName) { clip in
            var stack = clip.effects ?? []
            if let i = stack.firstIndex(where: { $0.type == Clip.debreathEffectType }) {
                stack[i].enabled = enabled
                if let clamped { stack[i].params["amount"] = EffectParam(value: clamped) }
            } else if enabled {
                stack.append(Effect(type: Clip.debreathEffectType, enabled: true, params: [
                    "amount": EffectParam(value: clamped ?? Clip.defaultDebreathAmount),
                ]))
            }
            clip.effects = stack.isEmpty ? nil : stack
        }
    }

    func setEnhance(clipIds: Set<String>, enabled: Bool, amount: Double? = nil, deess: Double? = nil, actionName: String) throws {
        if enabled { try AudioEnhancer.availability.requireAvailable() }
        mutateClips(ids: clipIds, actionName: actionName) { clip in
            Self.configureEnhancement(&clip, enabled: enabled,
                                      amount: amount.map { min(1, max(0, $0)) },
                                      deess: deess.map { min(1, max(0, $0)) })
        }
    }

    @discardableResult
    func enhanceVoice(clipIds: Set<String>, amount: Double, deess: Double, actionName: String) async throws -> [String] {
        try AudioEnhancer.availability.requireAvailable()
        guard amount.isFinite, deess.isFinite, (0...1).contains(amount), (0...1).contains(deess) else {
            throw AudioFinishingError(reason: "Enhancement amounts must be between 0 and 1.")
        }
        let (jobId, _) = try await startEnhancementJob(
            clipIds: clipIds,
            type: .enhance,
            params: .enhance(amount: amount, deess: deess),
            actionName: actionName
        )
        let job = try await awaitEnhancementJob(jobId)
        return job.warnings
    }

    @discardableResult
    func matchLoudness(
        clipIds: Set<String>, targetLUFS: Double, actionName: String,
        analyze: AudioLoudnessAnalysis? = nil
    ) async throws -> [String] {
        guard !clipIds.isEmpty, targetLUFS.isFinite, (-30...14).contains(targetLUFS) else {
            throw AudioFinishingError(reason: "Select audio clips and a target between -30 and 14 LUFS.")
        }
        let (jobId, _) = try await startEnhancementJob(
            clipIds: clipIds,
            type: .loudness,
            params: .loudness(targetLUFS: targetLUFS),
            actionName: actionName,
            analyze: analyze
        )
        let job = try await awaitEnhancementJob(jobId)
        return job.warnings
    }

    private struct AudioLoudnessTarget: Sendable {
        let id: String
        let mediaRef: String
        let url: URL
        let range: CMTimeRange
    }

    @concurrent
    private static func measureAudio(_ targets: [AudioLoudnessTarget], targetLUFS: Double, analyze: AudioLoudnessAnalysis) async throws
        -> (gains: [String: Double], warnings: [String], versions: [URL: LoudnessAnalyzer.SourceVersion]) {
        var gains: [String: Double] = [:]
        var warnings: [String] = []
        var versions: [URL: LoudnessAnalyzer.SourceVersion] = [:]
        for url in Set(targets.map(\.url)) { versions[url] = try LoudnessAnalyzer.SourceVersion(url) }
        for target in targets {
            try Task.checkCancellation()
            let measurement = try await analyze(target.url, target.mediaRef, target.range)
            guard let lufs = measurement.integratedLUFS, lufs.isFinite else {
                throw AudioFinishingError(reason: "Clip \(target.id) has insufficient audible material to measure loudness.")
            }
            let requested = targetLUFS - lufs
            let gain = min(24, max(-24, requested))
            gains[target.id] = gain
            if gain != requested {
                warnings.append("Clip \(target.id): gain limited to \(gain) dB; source loudness target was not reached.")
            }
            if let truePeak = measurement.truePeakDBFS, truePeak.isFinite {
                let projectedPeak = truePeak + gain
                if projectedPeak > 0 {
                    warnings.append("Clip \(target.id): target loudness \(targetLUFS) LUFS cannot be reached safely; gain of \(String(format: "%.1f", gain)) dB exceeds 0 dBFS headroom (projected true-peak \(String(format: "%.1f", projectedPeak)) dBTP).")
                } else if projectedPeak > -1.0 {
                    warnings.append("Clip \(target.id): target loudness \(targetLUFS) LUFS leaves less than 1 dB true-peak headroom (projected true-peak \(String(format: "%.1f", projectedPeak)) dBTP).")
                }
            }
        }
        return (gains, warnings, versions)
    }

    func awaitEnhancementAnalysis(clipIds: Set<String>) async throws -> [String] {
        let clipIdsArray = Array(clipIds)
        let clips = clipIdsArray.compactMap { clipFor(id: $0) }
        guard !clips.isEmpty else { return [] }
        let urls = mediaResolver.expectedURLMap()
        let missing = missingMediaRefs
        let fps = timeline.fps
        let width = timeline.width
        let height = timeline.height

        return try await Self.awaitEnhancementAnalysisInternal(
            clips: clips, urls: urls, missingMediaRefs: missing, fps: fps, width: width, height: height
        )
    }

    @concurrent
    private static func awaitEnhancementAnalysisInternal(
        clips: [Clip], urls: [String: URL], missingMediaRefs: Set<String>, fps: Int, width: Int, height: Int
    ) async throws -> [String] {
        var warnings: [String] = []
        var uniqueMediaRefs: Set<String> = []
        for clip in clips {
            guard clip.mediaType == .audio, clip.sourceClipType != .sequence,
                  !missingMediaRefs.contains(clip.mediaRef),
                  let _ = urls[clip.mediaRef] else { continue }
            uniqueMediaRefs.insert(clip.mediaRef)
        }
        if uniqueMediaRefs.isEmpty { return warnings }

        let prepClips = clips.filter { uniqueMediaRefs.contains($0.mediaRef) }
        let prepTimeline = Timeline(fps: fps, width: width, height: height,
                                    tracks: [Track(id: UUID().uuidString, type: .audio, clips: prepClips)])
        let result = try await PreparedAudio.prepare(
            timeline: prepTimeline, resolveTimeline: { _ in nil },
            resolveURL: { urls[$0] }, missingMediaRefs: missingMediaRefs
        )
        for ref in uniqueMediaRefs {
            let hasDebreath = clips.first { $0.mediaRef == ref }?.hasDebreathEnabled ?? false
            let hasEnhance = clips.first { $0.mediaRef == ref }?.hasEnhanceEnabled ?? false
            let hasDenoise = clips.first { $0.mediaRef == ref }?.hasDenoiseEnabled ?? false
            if (hasDebreath || hasEnhance) && result.breaths[ref] == nil {
                warnings.append("Breath detection unavailable for \(ref)")
            }
            if hasEnhance && result.sibilance[ref] == nil {
                warnings.append("De-ess analysis unavailable for \(ref)")
            }
            if (hasEnhance || hasDenoise) && result.denoisedURLs[ref] == nil {
                warnings.append("Denoising unavailable for \(ref)")
            }
        }
        return warnings
    }

    private static func configureEnhancement(_ clip: inout Clip, enabled: Bool, amount: Double?, deess: Double?) {
        if enabled { clip.effects?.removeAll { $0.type == Clip.denoiseEffectType || $0.type == Clip.debreathEffectType } }
        let exists = clip.effects?.contains { $0.type == Clip.enhanceEffectType } == true
        let values: [String: Double?] = enabled ? [
            "amount": exists ? amount : (amount ?? Clip.defaultEnhanceAmount),
            "deess": exists ? deess : (deess ?? Clip.defaultEnhanceDeess),
        ] : [:]
        setAudioEffect(&clip, type: Clip.enhanceEffectType, enabled: enabled, values: values.compactMapValues { $0 })
    }

    nonisolated static func setAudioEffect(_ clip: inout Clip, type: String, enabled: Bool, values: [String: Double]) {
        var stack = clip.effects ?? []
        if let index = stack.firstIndex(where: { $0.type == type }) {
            stack[index].enabled = enabled
            for (key, value) in values { stack[index].params[key] = EffectParam(value: value) }
        } else if enabled {
            stack.append(Effect(type: type, enabled: true, params: values.mapValues { EffectParam(value: $0) }))
        }
        clip.effects = stack.isEmpty ? nil : stack
    }
}
