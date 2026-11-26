import Foundation

struct PreparedAudio: Sendable {
    var denoisedURLs: [String: URL] = [:]
    var breaths: [String: [BreathDetector.Region]] = [:]
    var sibilance: [String: [DeEsser.Region]] = [:]

    private static let gate = AsyncSemaphore(value: 1)

    enum Stage: Sendable { case denoise, breath, deess }

    static func validateProcessing(_ clip: Clip) throws {
        let supported: Set<String> = [Clip.denoiseEffectType, Clip.debreathEffectType, Clip.loudnessEffectType, Clip.enhanceEffectType]
        var seen = Set<String>()
        for effect in clip.effects ?? [] where effect.enabled {
            guard supported.contains(effect.type), seen.insert(effect.type).inserted,
                  effect.params.values.allSatisfy({ $0.value?.isFinite ?? true }) else {
                throw AudioFinishingError(reason: "Clip '\(clip.id)' has unsupported, duplicated, or invalid audio processing '\(effect.type)'.")
            }
        }
        guard [clip.denoiseAmount, clip.debreathAmount, clip.enhanceAmount, clip.enhanceDeess].allSatisfy({
            $0.isFinite && (0...1).contains($0)
        }), clip.loudnessGainDB.isFinite, abs(clip.loudnessGainDB) <= 48, clip.freezeFrames == 0 else {
            throw AudioFinishingError(reason: "Clip '\(clip.id)' has unsupported audio processing parameters or freeze timing.")
        }
    }
    struct Failure: LocalizedError {
        let mediaRef: String
        let stage: Stage
        let reason: String
        var errorDescription: String? { "Audio preparation failed for \(mediaRef): \(reason)" }
    }

    static func audibleClips(timeline: Timeline, resolveTimeline: @Sendable (String) -> Timeline?) -> [Clip] {
        func expand(_ clips: [Clip], depth: Int) -> [Clip] {
            guard depth < NestFlattener.maxDepth else { return [] }
            return clips.flatMap { clip -> [Clip] in
                guard clip.durationFrames > 0 else { return [] }
                guard clip.sourceClipType == .sequence else { return [clip] }
                guard let child = resolveTimeline(clip.mediaRef) else { return [] }
                return NestFlattener.flatten(carrier: clip, child: child, visual: false).audioTracks.flatMap {
                    expand($0, depth: depth + 1)
                }
            }
        }
        return timeline.tracks.filter { $0.type == .audio && !$0.muted }.flatMap { expand($0.clips, depth: 0) }
    }

    @concurrent
    static func prepare(
        timeline: Timeline,
        resolveTimeline: @Sendable (String) -> Timeline?,
        resolveURL: @Sendable (String) -> URL?,
        missingMediaRefs: Set<String>
    ) async throws -> PreparedAudio {
        try Task.checkCancellation()
        try await gate.wait()
        do {
            let result = try await analyze(
                timeline: timeline, resolveTimeline: resolveTimeline,
                resolveURL: resolveURL, missingMediaRefs: missingMediaRefs
            )
            await gate.signal()
            return result
        } catch {
            await gate.signal()
            throw error
        }
    }

    private static func analyze(
        timeline: Timeline,
        resolveTimeline: @Sendable (String) -> Timeline?,
        resolveURL: @Sendable (String) -> URL?,
        missingMediaRefs: Set<String>
    ) async throws -> PreparedAudio {
        var result = PreparedAudio()
        for clip in audibleClips(timeline: timeline, resolveTimeline: resolveTimeline) {
            try Task.checkCancellation()
            try validateProcessing(clip)
            guard !missingMediaRefs.contains(clip.mediaRef), let url = resolveURL(clip.mediaRef) else { continue }
            let enhance = clip.hasEnhanceEnabled && clip.enhanceAmount > 0
            var stage = Stage.denoise
            do {
                if ((clip.hasDenoiseEnabled && clip.denoiseAmount > 0) || enhance), result.denoisedURLs[clip.mediaRef] == nil {
                    result.denoisedURLs[clip.mediaRef] = try await AudioEnhancer.denoisedAudio(for: url, mediaRef: clip.mediaRef)
                }
                stage = .breath
                if ((clip.hasDebreathEnabled && clip.debreathAmount > 0) || enhance), result.breaths[clip.mediaRef] == nil {
                    result.breaths[clip.mediaRef] = try await BreathDetector.analysis(for: url, mediaRef: clip.mediaRef).regions
                }
                stage = .deess
                if enhance && clip.enhanceDeess > 0, result.sibilance[clip.mediaRef] == nil {
                    result.sibilance[clip.mediaRef] = try await DeEsser.analysis(for: url, mediaRef: clip.mediaRef).regions
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Failure(mediaRef: clip.mediaRef, stage: stage, reason: error.localizedDescription)
            }
        }
        try Task.checkCancellation()
        return result
    }
}
