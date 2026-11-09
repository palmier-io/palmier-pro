import AVFoundation
import Foundation

extension EditorViewModel {
    typealias AudioLoudnessAnalysis = @Sendable (URL, String, CMTimeRange) async throws -> LoudnessMeasurement

    func resetAnalysisSessionState() {
        denoiseFailed.removeAll()
        breathFailed.removeAll()
        deessFailed.removeAll()
        mediaVisualCache.resetSessionState()
        for id in openTimelineIds { videoEngine?.evictComposition(for: id) }
        videoEngine?.rebuild()
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
