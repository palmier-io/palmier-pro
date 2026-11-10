import AVFoundation
import Foundation

extension EditorViewModel {
    typealias AudioLoudnessAnalysis = @Sendable (URL, String, CMTimeRange) async throws -> LoudnessMeasurement

    func resetAnalysisSessionState() {
        denoiseFailed.removeAll()
        breathFailed.removeAll()
        deessFailed.removeAll()
        enhancementJobs.removeAll()
        enhancementJobFingerprints.removeAll()
        mediaVisualCache.resetSessionState()
        for id in openTimelineIds { videoEngine?.evictComposition(for: id) }
        videoEngine?.rebuild()
    }

    // MARK: - Enhancement job management

    /// Creates a fingerprint for deduplication: clipIds + mediaRefs + type + params + source versions
    private func enhancementFingerprint(clipIds: Set<String>, type: EnhancementJob.JobType, params: EnhancementJob.JobParams) -> String {
        let mediaRefs = clipIds.compactMap { clipFor(id: $0)?.mediaRef }.sorted()
        let versions = mediaRefs.compactMap { ref -> String? in
            guard let url = mediaResolver.expectedURL(for: ref) else { return nil }
            do { return try LoudnessAnalyzer.SourceVersion(url).url } catch { return nil }
        }.sorted()
        let paramStr = "\(params.amount ?? 0)-\(params.deess ?? 0)-\(params.targetLUFS ?? 0)-\(params.enabled)"
        return "\(type.rawValue)|\(clipIds.sorted().joined(separator: ","))|\(mediaRefs.joined(separator: ","))|\(versions.joined(separator: ","))|\(paramStr)"
    }

    /// Finds an existing job with the same fingerprint that's still running/queued
    private func existingJob(fingerprint: String) -> EnhancementJob? {
        guard let jobId = enhancementJobFingerprints[fingerprint],
              let job = enhancementJobs[jobId],
              job.status == .queued || job.status == .running else { return nil }
        return job
    }

    /// Starts or reuses an enhancement job. Returns (jobId, isNewJob).
    @discardableResult
    func startEnhancementJob(
        clipIds: Set<String>,
        type: EnhancementJob.JobType,
        params: EnhancementJob.JobParams,
        actionName: String
    ) async throws -> (UUID, Bool) {
        // Validate clips exist and are audio
        let clips = clipIds.compactMap { clipFor(id: $0) }
        guard clips.count == clipIds.count else { throw AudioFinishingError(reason: "One or more clips not found.") }
        guard clips.allSatisfy({ $0.mediaType == .audio && $0.sourceClipType != .sequence }) else {
            throw AudioFinishingError(reason: "Enhancement only supports non-nested audio clips.")
        }
        // Check for missing media
        let urls = mediaResolver.expectedURLMap()
        let missingRefs = clips.compactMap { clip in
            missingMediaRefs.contains(clip.mediaRef) || urls[clip.mediaRef] == nil ? clip.mediaRef : nil
        }
        guard missingRefs.isEmpty else {
            throw AudioFinishingError(reason: "Missing media for: \(missingRefs.joined(separator: ", "))")
        }

        let fingerprint = enhancementFingerprint(clipIds: clipIds, type: type, params: params)
        if let existing = existingJob(fingerprint: fingerprint) {
            return (existing.id, false)
        }

        // Capture source versions for revalidation
        var versions: [String: LoudnessAnalyzer.SourceVersion] = [:]
        for clip in clips {
            if let url = urls[clip.mediaRef] { versions[clip.mediaRef] = try LoudnessAnalyzer.SourceVersion(url) }
        }

        let job = EnhancementJob(
            id: UUID(),
            clipIds: clipIds,
            mediaRefs: Set(clips.map(\.mediaRef)),
            type: type,
            params: params,
            sourceVersions: versions,
            startedAt: Date(),
            status: .queued,
            stage: .queued,
            errors: [],
            warnings: [],
            changedClipIds: []
        )
        enhancementJobs[job.id] = job
        enhancementJobFingerprints[fingerprint] = job.id

        // Run the job asynchronously
        let jobId = job.id
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runEnhancementJob(jobId: jobId)
        }
        return (jobId, true)
    }

    private func runEnhancementJob(jobId: UUID) async {
        await updateJobStatus(jobId, status: .running, stage: .analyzing)
        do {
            var job = try await getJob(jobId)
            let clips = job.clipIds.compactMap { clipFor(id: $0) }
            let urls = mediaResolver.expectedURLMap()
            let missing = missingMediaRefs

            switch job.type {
            case .denoise:
                for clip in clips {
                    try Task.checkCancellation()
                    guard let url = urls[clip.mediaRef] else { continue }
                    _ = try await AudioEnhancer.denoisedAudio(for: url, mediaRef: clip.mediaRef)
                    await appendChanged(jobId, clip.id)
                }
            case .debreath, .enhance:
                // Run through PreparedAudio to get all analyses
                let prepTimeline = Timeline(fps: timeline.fps, width: timeline.width, height: timeline.height,
                                            tracks: [Track(id: UUID().uuidString, type: .audio, clips: clips)])
                let result = try await PreparedAudio.prepare(
                    timeline: prepTimeline, resolveTimeline: { _ in nil },
                    resolveURL: { urls[$0] }, missingMediaRefs: missing
                )
                // Verify we got what we needed
                for ref in job.mediaRefs {
                    try Task.checkCancellation()
                    if job.type == .enhance {
                        if result.denoisedURLs[ref] == nil { await appendWarning(jobId, "Denoising unavailable for \(ref)") }
                        if result.breaths[ref] == nil { await appendWarning(jobId, "Breath detection unavailable for \(ref)") }
                        if result.sibilance[ref] == nil { await appendWarning(jobId, "De-ess analysis unavailable for \(ref)") }
                    } else if job.type == .debreath {
                        if result.breaths[ref] == nil { await appendWarning(jobId, "Breath detection unavailable for \(ref)") }
                    }
                    await appendChanged(jobId, clips.first { $0.mediaRef == ref }?.id ?? "")
                }
            case .loudness:
                let targets = clips.compactMap { clip -> AudioLoudnessTarget? in
                    guard let url = urls[clip.mediaRef] else { return nil }
                    let range = try? LoudnessAnalyzer.sourceRange(for: clip, fps: timeline.fps)
                    return range.map { AudioLoudnessTarget(id: clip.id, mediaRef: clip.mediaRef, url: url, range: $0) }
                }
                guard !targets.isEmpty else { await appendError(jobId, "No valid clips for loudness analysis"); return }
                let measured = try await Self.measureAudio(targets, targetLUFS: job.params.targetLUFS ?? -16, analyze: { url, ref, range in
                    try await LoudnessAnalyzer.integratedLoudness(for: url, mediaRef: ref, range: range)
                })
                for (id, gain) in measured.gains {
                    try Task.checkCancellation()
                    guard var clip = clipFor(id: id) else { continue }
                    Self.setAudioEffect(&clip, type: Clip.loudnessEffectType, enabled: true, values: ["gainDB": gain])
                    mutateClips(ids: [id], actionName: "Match Loudness (Job)") { $0 = clip }
                    await appendChanged(jobId, id)
                }
            }
            await finishJob(jobId, success: true)
        } catch is CancellationError {
            await finishJob(jobId, success: false, error: "Cancelled")
        } catch {
            await finishJob(jobId, success: false, error: error.localizedDescription)
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
    private func appendError(_ id: UUID, _ error: String) {
        guard var job = enhancementJobs[id] else { return }
        job.errors.append(error)
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
        guard var job = enhancementJobs[id] else { return }
        if let error { job.errors.append(error) }
        job.status = success ? .completed : .failed
        job.stage = success ? .completed : .failed
        enhancementJobs[id] = job
        // Clean up fingerprint after a delay to allow quick re-submission to dedupe
        let fingerprint = enhancementFingerprint(clipIds: job.clipIds, type: job.type, params: job.params)
        Task { try? await Task.sleep(for: .seconds(5)); await removeFingerprint(fingerprint) }
    }

    @MainActor
    func removeFingerprint(_ fingerprint: String) {
        enhancementJobFingerprints.removeValue(forKey: fingerprint)
    }

    func cancelEnhancementJob(_ id: UUID) {
        guard var job = enhancementJobs[id] else { return }
        job.status = .cancelled
        job.stage = .cancelled
        enhancementJobs[id] = job
    }

    func getEnhancementJobStatus(_ id: UUID) -> (status: String, stage: String, errors: [String], warnings: [String], changed: [String], progress: Double)? {
        guard let job = enhancementJobs[id] else { return nil }
        let progress: Double = {
            switch job.stage {
            case .queued: return 0
            case .analyzing: return 0.3
            case .applying: return 0.7
            case .completed: return 1.0
            case .failed: return 1.0
            case .cancelled: return 1.0
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
                case .completed: return 1.0
                case .failed: return 1.0
                case .cancelled: return 1.0
                }
            }()
            return (job.id, job.type.rawValue, job.status.rawValue, job.clipIds.count, progress, job.startedAt)
        }
        return jobs.sorted { $0.startedAt < $1.startedAt }.map { ($0.id, $0.type, $0.status, $0.clipCount, $0.progress) }
    }

    /// Waits for all running/queued enhancement jobs for the given clip IDs to complete.
    /// Returns warnings from completed jobs. Throws if any job fails or is cancelled.
    func awaitEnhancementJobsForClips(_ clipIds: Set<String>) async throws -> [String] {
        var allWarnings: [String] = []
        
        while true {
            let pendingJobs = enhancementJobs.values.filter { job in
                !job.clipIds.isDisjoint(with: clipIds) &&
                (job.status == .queued || job.status == .running)
            }
            if pendingJobs.isEmpty { break }
            
            // Wait for the first pending job to complete
            let jobId = pendingJobs.first!.id
            var lastStage = pendingJobs.first!.stage
            while true {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(100))
                guard let job = enhancementJobs[jobId] else { break }
                if job.stage != lastStage || job.stage == .completed || job.stage == .failed || job.stage == .cancelled {
                    lastStage = job.stage
                    if job.stage == .completed {
                        allWarnings.append(contentsOf: job.warnings)
                    } else if job.stage == .failed || job.stage == .cancelled {
                        throw AudioFinishingError(reason: "Enhancement job \(jobId) \(job.stage.rawValue): \(job.errors.joined(separator: "; "))")
                    }
                    break
                }
            }
        }
        
        // Collect warnings from completed jobs
        for job in enhancementJobs.values where !job.clipIds.isDisjoint(with: clipIds) {
            allWarnings.append(contentsOf: job.warnings)
        }
        return allWarnings
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
        return try await finishAudio(clipIds: clipIds, targetLUFS: -16, actionName: actionName) { clip in
            Self.configureEnhancement(&clip, enabled: true, amount: amount, deess: deess)
        }
    }

    @discardableResult
    func matchLoudness(
        clipIds: Set<String>, targetLUFS: Double, actionName: String,
        analyze: @escaping AudioLoudnessAnalysis = { url, ref, range in
            try await LoudnessAnalyzer.integratedLoudness(for: url, mediaRef: ref, range: range)
        }
    ) async throws -> [String] {
        try await finishAudio(clipIds: clipIds, targetLUFS: targetLUFS, actionName: actionName, analyze: analyze) { _ in }
    }

    struct AudioFinishingError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private func finishAudio(
        clipIds: Set<String>, targetLUFS: Double, actionName: String,
        analyze: @escaping AudioLoudnessAnalysis = { url, ref, range in
            try await LoudnessAnalyzer.integratedLoudness(for: url, mediaRef: ref, range: range)
        },
        configure: (inout Clip) -> Void
    ) async throws -> [String] {
        try Task.checkCancellation()
        guard !clipIds.isEmpty, targetLUFS.isFinite, (-30...14).contains(targetLUFS) else {
            throw AudioFinishingError(reason: "Select audio clips and a target between -30 and 14 LUFS.")
        }
        guard loudnessInFlight.isDisjoint(with: clipIds) else {
            throw AudioFinishingError(reason: "Loudness matching is already running for these clips.")
        }
        let snapshot = timeline
        let revision = timelineRenderRevision
        let urls = mediaResolver.expectedURLMap()
        var replacements: [String: Clip] = [:]
        var targets: [AudioLoudnessTarget] = []
        for id in clipIds.sorted() {
            guard let clip = clipFor(id: id), clip.mediaType == .audio, clip.sourceClipType != .sequence,
                  !missingMediaRefs.contains(clip.mediaRef), let url = urls[clip.mediaRef] else {
                throw AudioFinishingError(reason: "Audio clip \(id) is unavailable or nested.")
            }
            var replacement = clip
            configure(&replacement)
            replacements[id] = replacement
            targets.append(AudioLoudnessTarget(id: id, mediaRef: clip.mediaRef, url: url,
                                              range: try LoudnessAnalyzer.sourceRange(for: clip, fps: snapshot.fps)))
        }
        loudnessInFlight.formUnion(clipIds)
        defer { loudnessInFlight.subtract(clipIds) }
        let measured = try await Self.measureAudio(targets, targetLUFS: targetLUFS, analyze: analyze)
        for (id, gain) in measured.gains {
            guard var clip = replacements[id] else { continue }
            Self.setAudioEffect(&clip, type: Clip.loudnessEffectType, enabled: true, values: ["gainDB": gain])
            replacements[id] = clip
        }
        var preparation = snapshot
        preparation.tracks = [Track(id: UUID().uuidString, type: .audio, clips: Array(replacements.values))]
        _ = try await PreparedAudio.prepare(timeline: preparation, resolveTimeline: { _ in nil },
                                            resolveURL: { urls[$0] }, missingMediaRefs: [])
        return try await projectPackageCoordinator.withMutation { _ in
            try await LoudnessAnalyzer.validateSourceVersions(measured.versions)
            try Task.checkCancellation()
            guard timelineRenderRevision == revision, timeline == snapshot,
                  targets.allSatisfy({ mediaResolver.expectedURL(for: $0.mediaRef) == $0.url }) else {
                throw AudioFinishingError(reason: "Timeline or source changed during audio finishing. Retry with the current clips.")
            }
            let changed = clipIds.filter { clipFor(id: $0) != replacements[$0] }
            if !changed.isEmpty {
                mutateClips(ids: changed, actionName: actionName) { clip in
                    if let replacement = replacements[clip.id] { clip = replacement }
                }
            }
            return measured.warnings
        }
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
        }
        return (gains, warnings, versions)
    }

    /// Awaits breath and de-ess analysis for the given clips.
    /// Returns warnings for any clips where analysis failed.
    func awaitEnhancementAnalysis(clipIds: Set<String>) async throws -> [String] {
        // Capture required data on main actor
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

    private static func setAudioEffect(_ clip: inout Clip, type: String, enabled: Bool, values: [String: Double]) {
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
